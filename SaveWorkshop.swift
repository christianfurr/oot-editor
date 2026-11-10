// Adapted from Traiver/OOT-SW2SE (MIT); see Vendor/OOT-SW2SE/LICENSE.
// OOTSW2SE.swift
//
// Native macOS host for the OOT SW2SE save editor.
//
// The upstream project keeps all editor logic (UI, save parser, patch ZIP
// generator) in ../editor.html and wraps it in a Windows WebView2 shell
// (../Program.cs). This file is the macOS equivalent of that shell: an AppKit
// window with a WKWebView that loads the same editor.html unchanged.
//
// The page talks to its host through `window.chrome.webview` (the WebView2
// bridge). We inject a tiny shim that provides that object on top of WebKit's
// `window.webkit.messageHandlers`, then implement the three host actions the
// page uses:
//   - "openBackup": pick a backup/save folder and return its .sav files as base64
//   - "savePatch":  receive the patch ZIP as base64 and save it with a save panel
//   - "workspace":  resize the window between the small landing size and the
//                   full editor size
// Size limits and the basic folder rules mirror Program.cs so both hosts accept
// the same backups. Where the Windows host has gaps (a slot or "files" folder
// picked directly, files being written meanwhile, cloud placeholders) this host
// handles them; see BackupReader.

import AppKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Constants

/// Values shared with the Windows host so both builds accept the same input.
enum HostLimits {
    /// Maximum total bytes read from one backup (8 MiB, as in Program.cs).
    static let maxBackupBytes = 8 * 1024 * 1024
    /// Maximum size of a single .sav / manifest file (2 MiB, as in Program.cs).
    static let maxFileBytes = 2 * 1024 * 1024
    /// Number of save slots the game uses (slot_00 ... slot_05).
    static let slotCount = 6
}

/// The editor version substituted into the page's `{{EDITOR_VERSION}}` placeholder.
/// Read from the bundle's Info.plist so it only has to be bumped in build.sh.
let editorVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"

/// Origin the page is loaded under. An https origin makes the page a secure
/// context, which the editor needs for `crypto.subtle` (SHA-256 of save files).
/// Nothing is ever fetched from this host: the HTML is supplied from memory and
/// the page's own CSP blocks all network access.
let pageURL = URL(string: "https://editor.oot.local/index.html")!

/// Script injected before the page runs. It recreates the subset of the
/// WebView2 `window.chrome.webview` API that editor.html uses
/// (postMessage + addEventListener('message')), forwarding messages to the
/// native "host" handler and exposing `__ootHostReply` for native replies.
/// User scripts are not subject to the page's Content-Security-Policy.
let bridgeShim = """
(() => {
  const listeners = new Set();
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    postMessage(message) {
      window.webkit.messageHandlers.host.postMessage(JSON.stringify(message));
    },
    addEventListener(type, listener) {
      if (type === 'message') listeners.add(listener);
    },
    removeEventListener(type, listener) {
      if (type === 'message') listeners.delete(listener);
    },
  };
  Object.defineProperty(window, '__ootHostReply', {
    value: data => { for (const listener of listeners) listener({ data }); },
  });
})();
"""

// MARK: - Errors

/// Errors whose message is shown to the user by the editor page.
struct HostError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Backup reading

/// Reads save files from a folder chosen by the user. Based on
/// `EditorWindow.ReadBackup` in Program.cs, with the extra layouts and checks
/// described on `read(folder:)` and `readFile`.
enum BackupReader {
    /// One file sent to the page: a virtual relative path plus base64 contents.
    typealias Entry = [String: String]

    /// Virtual folder the page sees for backup slots ("Backup/files/slot_00/...").
    private static let backupPrefix = "Backup/files/"

    /// Returns the files of a backup or single-save folder.
    ///
    /// Accepted layouts:
    ///   1. A slot folder (slot_00 ... slot_05) picked directly. It is sent as a
    ///      one-slot backup, with option.sav and manifest.json from around it,
    ///      so the patch keeps backup paths and the voice language stays
    ///      editable. (The Windows host sends it as a bare "slot_00/" folder,
    ///      which loses both.)
    ///   2. Any other folder that directly holds progress.sav + caption.sav
    ///      (one loose save), optionally with option.sav next to them.
    ///   3. A backup folder with slot_00...slot_05 subfolders, either directly
    ///      or inside a "files" subfolder, plus optional option.sav and
    ///      manifest.json. Picking the "files" folder itself works too.
    /// - Throws: `HostError` when no save pair is found or limits are exceeded.
    static func read(folder: URL) throws -> [Entry] {
        var files: [Entry] = []
        var totalBytes = 0
        let prefix = backupPrefix

        if let slot = slotName(folder.lastPathComponent), hasSavePair(folder) {
            try readPair(into: &files, folder: folder, prefix: prefix + slot + "/", total: &totalBytes)
            try readExtras(into: &files, slotsFolder: folder.deletingLastPathComponent(), total: &totalBytes)
            return files
        }

        if hasSavePair(folder) {
            // The page expects "<name>/progress.sav"; fall back to "Save" for
            // names that would break its path parsing.
            var name = folder.lastPathComponent
            if name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains(where: { "/\\:".contains($0) }) {
                name = "Save"
            }
            try readPair(into: &files, folder: folder, prefix: name + "/", total: &totalBytes)
            let localOption = folder.appendingPathComponent("option.sav")
            if exists(localOption) {
                try readFile(into: &files, url: localOption, relativePath: name + "/option.sav", total: &totalBytes)
            }
            return files
        }

        // Prefer a "files" subfolder, but only if it really holds slots: an
        // empty or unrelated "files" folder must not hide slots at the root.
        let nested = folder.appendingPathComponent("files")
        let slotsFolder = isDirectory(nested) && !slotFolders(in: nested).isEmpty ? nested : folder
        let slots = slotFolders(in: slotsFolder)
        if slots.isEmpty {
            throw HostError("No folder containing progress.sav and caption.sav was found.")
        }
        for (slot, slotFolder) in slots {
            try readPair(into: &files, folder: slotFolder, prefix: prefix + slot + "/", total: &totalBytes)
        }
        try readExtras(into: &files, slotsFolder: slotsFolder, total: &totalBytes)
        return files
    }

    /// The slot subfolders of `folder` that hold a complete save, in slot
    /// order, as (canonical name, URL) pairs.
    private static func slotFolders(in folder: URL) -> [(String, URL)] {
        (0..<HostLimits.slotCount).compactMap { index in
            let slot = String(format: "slot_%02d", index)
            let url = folder.appendingPathComponent(slot)
            return hasSavePair(url) ? (slot, url) : nil
        }
    }

    /// Returns the canonical lowercase slot name ("slot_03") when `name` is a
    /// slot folder name in any letter case, else nil. The page only matches
    /// lowercase slot names, and case-insensitive volumes may report others.
    private static func slotName(_ name: String) -> String? {
        let lower = name.lowercased()
        guard lower.count == 7, lower.hasPrefix("slot_0"), let digit = lower.last?.wholeNumberValue,
              digit < HostLimits.slotCount else { return nil }
        return lower
    }

    /// Adds the backup-wide files that sit around the slots: option.sav next
    /// to the slot folders, and manifest.json in the backup root, which is the
    /// parent of a folder named "files" (so picking "files" itself still
    /// finds the manifest and keeps it in sync with the patch).
    private static func readExtras(into files: inout [Entry], slotsFolder: URL, total: inout Int) throws {
        let option = slotsFolder.appendingPathComponent("option.sav")
        if exists(option) {
            try readFile(into: &files, url: option, relativePath: backupPrefix + "option.sav", total: &total)
        }
        let root = slotsFolder.lastPathComponent.lowercased() == "files"
            ? slotsFolder.deletingLastPathComponent() : slotsFolder
        let manifest = root.appendingPathComponent("manifest.json")
        if exists(manifest) {
            try readFile(into: &files, url: manifest, relativePath: "Backup/manifest.json", total: &total)
        }
    }

    /// True when `folder` holds both files that make up one save slot.
    private static func hasSavePair(_ folder: URL) -> Bool {
        exists(folder.appendingPathComponent("progress.sav")) && exists(folder.appendingPathComponent("caption.sav"))
    }

    /// Reads progress.sav and caption.sav of one slot.
    private static func readPair(into files: inout [Entry], folder: URL, prefix: String, total: inout Int) throws {
        for name in ["progress.sav", "caption.sav"] {
            try readFile(into: &files, url: folder.appendingPathComponent(name), relativePath: prefix + name, total: &total)
        }
    }

    /// Reads one file, enforcing the per-file and per-backup size limits
    /// before loading it, and appends it base64-encoded to `files`.
    ///
    /// Only regular files are opened (symlinks are resolved first): opening a
    /// FIFO or device would block forever and leave the editor stuck. Files
    /// that are only placeholders (iCloud or another cloud provider has not
    /// downloaded them) are refused too, since reading one blocks until the
    /// download finishes, with no progress or way to cancel.
    /// - Throws: `HostError` for non-regular, placeholder, oversized,
    ///   truncated or changed files, or the underlying I/O error.
    private static func readFile(into files: inout [Entry], url: URL, relativePath: String, total: inout Int) throws {
        var target = url.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let values = try target.resourceValues(forKeys: keys)
        guard values.isRegularFile == true else {
            throw HostError("\(relativePath) is not a regular file.")
        }
        if isDataless(target) {
            throw HostError("\(relativePath) is not downloaded yet. Download it in Finder, then try again.")
        }
        let limit = min(HostLimits.maxFileBytes, HostLimits.maxBackupBytes - total)
        let size = values.fileSize ?? 0
        if size > limit {
            throw HostError("The backup files exceed the expected size.")
        }
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        // Read at most one byte past the limit, so a file that grew after the
        // size check is rejected without being loaded whole.
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        if data.count > limit {
            throw HostError("The backup files exceed the expected size.")
        }
        // Same check as Program.cs: fewer bytes than reported means the file
        // shrank or the read stopped early, so the copy would be incomplete.
        if data.count < size {
            throw HostError("A backup file was truncated while reading it.")
        }
        // macOS has no equivalent of the FileShare.Read lock Program.cs relies
        // on to refuse files another program is writing. Compare size and
        // modification date before and after instead: a change means the copy
        // may mix old and new data.
        target.removeAllCachedResourceValues()
        let after = try target.resourceValues(forKeys: keys)
        if after.fileSize != values.fileSize || after.contentModificationDate != values.contentModificationDate {
            throw HostError("\(relativePath) changed while it was being read. Close the game or emulator, then try again.")
        }
        total += data.count
        files.append(["relativePath": relativePath, "contents": data.base64EncodedString()])
    }

    /// True for an existing regular file, following symlinks. Folders, FIFOs
    /// and devices return false so they are never treated as save files.
    private static func exists(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// True when the file's data is not on disk yet (SF_DATALESS, set on
    /// placeholders created by iCloud Drive and other File Provider apps).
    private static func isDataless(_ url: URL) -> Bool {
        // Value of SF_DATALESS in <sys/stat.h>; spelled out because the macro
        // is not imported into Swift on every SDK.
        let datalessFlag: UInt32 = 0x4000_0000
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
    }

    /// True for an existing folder.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Script message proxy

/// Forwards script messages to a weakly held handler.
///
/// WKUserContentController keeps its message handlers alive with a strong
/// reference. Registering the window controller directly would form the cycle
/// controller -> web view -> configuration -> content controller -> controller,
/// so the window and its web content process could never be freed.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    /// - Parameter target: the real handler; not retained.
    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    /// Passes the message on, or drops it once the target is gone.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Web view

/// WKWebView without the browser items of its right-click menu.
///
/// Program.cs turns WebView2's context menu off entirely. Here the editing
/// items (Cut, Copy, Paste, spelling) stay useful in text fields, so only the
/// items that navigate or inspect are removed: "Reload" in particular would
/// silently throw away every unsaved edit.
final class EditorWebView: WKWebView {
    /// Identifiers of the menu items to drop. WebKit exports these names
    /// (WKMenuItemIdentifier...) but has no public header for them, so they
    /// are matched as strings; if WebKit ever renames one, the item simply
    /// stays, and the controller still resets itself on reload.
    private static let blockedItems: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierInspectElement", "WKMenuItemIdentifierOpenLink",
        "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierDownloadMedia",
    ]

    /// Removes the blocked items, then tidies separators so the menu does not
    /// start, end or double up on a divider (or show as an empty box).
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items where Self.blockedItems.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
    }
}

// MARK: - Folder export

enum PatchFolderWriter {
    static func timestamp(_ name: String) throws -> String {
        let pattern = #"\AOcarina-of-Time-(?:Save|slot_0[0-5])-Patch-([0-9]{8}_[0-9]{6})_[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { throw HostError("Invalid patch folder name.") }
        return String(name[range])
    }

    static func decode(_ entries: [[String: String]]?, name: String) throws -> [String: Data] {
        let stamp = try timestamp(name)
        guard let entries, (2...4).contains(entries.count) else { throw HostError("Invalid patch file list.") }
        let pattern = #"\A(?:manifest\.json|"# + stamp + #"/(?:progress\.sav|caption\.sav|option\.sav|slot_0[0-5]/(?:progress|caption)\.sav))\z"#
        var files: [String: Data] = [:]
        var total = 0
        for entry in entries {
            guard let path = entry["relativePath"], path.range(of: pattern, options: .regularExpression) != nil,
                  files[path] == nil, let contents = entry["contents"], !contents.isEmpty,
                  contents.utf8.count <= HostLimits.maxFileBytes * 2,
                  let bytes = Data(base64Encoded: contents), !bytes.isEmpty else {
                throw HostError("Invalid patch file.")
            }
            total += bytes.count
            guard bytes.count <= HostLimits.maxFileBytes, total <= HostLimits.maxBackupBytes else {
                throw HostError("The patch files are too large.")
            }
            files[path] = bytes
        }
        return files
    }

    static func write(parent: URL, files: [String: Data], name: String) throws -> URL {
        _ = try timestamp(name)
        let fm = FileManager.default
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".oot-patch-" + token, isDirectory: true)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for (path, bytes) in files {
            let target = staging.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .withoutOverwriting)
        }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }
}

// MARK: - Editor window

/// Callback that finishes one bridge request on the main actor: a result
/// (or nil when the user cancels) or an error.
typealias Completion = @MainActor (Any?, Error?) -> Void

/// The single editor window: hosts the WKWebView, answers bridge messages and
/// resizes itself when the page switches between landing and editor views.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate,
                                    WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    /// Window background, matching the page's `#101b18` so there is no flash.
    private static let background = NSColor(red: 16 / 255, green: 27 / 255, blue: 24 / 255, alpha: 1)
    /// Content size of the landing view (before a save is loaded), in points.
    private static let landingSize = NSSize(width: 570, height: 300)
    /// Content size of the full editor, in points.
    private static let editorSize = NSSize(width: 1100, height: 730)
    /// Smallest content size allowed once the editor is shown.
    private static let editorMinimum = NSSize(width: 740, height: 500)

    private var webView: WKWebView!
    /// Guards against overlapping panels, like `dialogOpen` in Program.cs.
    private var dialogOpen = false
    /// Whether the full editor (not the landing view) is currently shown.
    private var workspaceLoaded = false
    /// Folder of the last opened backup, used as the next panel's start folder.
    private var lastFolder: URL?
    /// Incremented on every page load (first load, crash recovery, or any
    /// other reload). Replies to requests made by an earlier page are
    /// dropped, because the new page reuses request ids starting from 1.
    private var pageGeneration = 0
    /// The folder panel while it is open. It is a standalone window, so a
    /// click on the editor window can cover it; it is brought back on top.
    private var activePanel: NSOpenPanel?

    /// Creates the landing-size window and its web view, installs the bridge
    /// shim and starts loading the editor page.
    init(defaultFolder: URL?) {
        lastFolder = defaultFolder
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.landingSize),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "OoT Editor · Save Workshop"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Self.background
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakScriptMessageHandler(self), name: "host")
        configuration.userContentController = controller
        // The editor is fully offline; keep nothing on disk between launches.
        configuration.websiteDataStore = .nonPersistent()

        webView = EditorWebView(frame: window.contentLayoutRect, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = Self.background
        // Transparent until the page paints, so the dark window shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView

        applyLayout(loaded: false)
        loadEditor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Loads editor.html from the app bundle with the version filled in.
    private func loadEditor() {
        guard let url = Bundle.main.url(forResource: "editor", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            showFatal("editor.html is missing from the application bundle.")
            return
        }
        // pageGeneration and the window layout are reset in didCommit, which
        // runs for this load and for any reload the user triggers.
        webView.loadHTMLString(html.replacingOccurrences(of: "{{EDITOR_VERSION}}", with: editorVersion), baseURL: pageURL)
    }

    /// Resizes and recenters the window for the landing or editor view.
    /// The landing view is fixed-size; the editor view is resizable with a minimum.
    ///
    /// In full screen the frame can't be changed: going back to the landing
    /// view leaves full screen first and finishes in windowDidExitFullScreen;
    /// the editor view needs nothing, as full screen is already large.
    private func applyLayout(loaded: Bool) {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            if !loaded { window.toggleFullScreen(nil) }
            return
        }
        // Before the window is first shown, open it on the screen with the
        // mouse pointer, like Program.cs (Screen.FromPoint(Cursor.Position)).
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        guard let screen = (window.isVisible ? window.screen : mouseScreen) ?? NSScreen.main else { return }
        if loaded {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
        let area = screen.visibleFrame
        let requested = window.frameRect(forContentRect: NSRect(origin: .zero, size: loaded ? Self.editorSize : Self.landingSize))
        let width = min(requested.width, area.width)
        let height = min(requested.height, area.height)
        window.contentMinSize = loaded
            ? NSSize(width: min(Self.editorMinimum.width, width), height: min(Self.editorMinimum.height, height))
            : .zero
        window.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height),
                        display: true, animate: window.isVisible)
    }

    // MARK: Bridge

    /// Handles a message posted by the page through the shim.
    /// Requests with an id get exactly one reply; "workspace" gets none.
    /// WebKit delivers script messages on the main thread.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Like the e.Source check in Program.cs: only the editor page itself may
        // use the host. Message handlers are visible to every frame, not just
        // the main frame the shim is injected into.
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              origin.protocol == pageURL.scheme, origin.host == pageURL.host else { return }
        guard let text = message.body as? String,
              let data = text.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        handle(request)
    }

    /// Dispatches one decoded bridge request.
    ///
    /// "workspace" resizes the window and gets no reply. Every other request
    /// must carry an id >= 1 and gets exactly one reply: a result, `nil` when
    /// the user cancels, or an error. Only one panel request runs at a time;
    /// overlapping ones are refused, as in Program.cs.
    private func handle(_ request: [String: Any]) {
        let action = request["action"] as? String
        if action == "workspace" {
            let loaded = request["loaded"] as? Bool ?? false
            if loaded != workspaceLoaded {
                workspaceLoaded = loaded
                applyLayout(loaded: loaded)
            }
            return
        }
        guard let id = request["id"] as? Int, id >= 1 else { return }
        if dialogOpen {
            reply(id: id, result: nil, error: "A file dialog is already open.")
            return
        }
        dialogOpen = true
        let generation = pageGeneration
        let finish: Completion = { [weak self] result, error in
            guard let self else { return }
            self.dialogOpen = false
            // The page that asked may have been replaced by a reload.
            guard generation == self.pageGeneration else { return }
            self.reply(id: id, result: result, error: error?.localizedDescription)
        }
        switch action {
        case "openBackup":
            openBackup(completion: finish)
        case "saveFolder":
            saveFolder(entries: request["files"] as? [[String: String]], name: request["name"] as? String, completion: finish)
        case "savePatch":
            savePatch(name: request["name"] as? String, contents: request["contents"] as? String, completion: finish)
        default:
            finish(nil, HostError("Unknown editor action."))
        }
    }

    /// Sends `{id, result, error}` back to the page's pending promise.
    private func reply(id: Int, result: Any?, error: String?) {
        let payload: [String: Any] = ["id": id, "result": result ?? NSNull(), "error": error ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__ootHostReply(\(json));", completionHandler: nil)
    }

    // MARK: Host actions

    /// Asks for a backup or save folder, then reads it off the main thread.
    /// Completes with `nil` when the user cancels.
    private func openBackup(completion: @escaping Completion) {
        let panel = NSOpenPanel()
        panel.message = "Select a backup or save folder"
        panel.prompt = "Select Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = lastFolder
        // A standalone panel, not a sheet: the landing window (570x300) is
        // smaller than the panel, so a sheet would be cramped and clipped.
        // Re-entry while it is open is blocked by `dialogOpen`, and
        // windowDidBecomeKey keeps it in front of the editor window.
        activePanel = panel
        panel.begin { [weak self] response in
            self?.activePanel = nil
            guard response == .OK, let folder = panel.url else { return completion(nil, nil) }
            self?.lastFolder = folder
            // Read off the main actor; the page waits on its pending promise.
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    Result { try BackupReader.read(folder: folder) }
                }.value
                switch outcome {
                case .success(let files): completion(files, nil)
                case .failure(let error): completion(nil, error)
                }
            }
        }
    }

    /// Validates the patch ZIP from the page and saves it where the user picks.
    /// Completes with the saved file name, or `nil` when the user cancels.
    private func savePatch(name: String?, contents: String?, completion: @escaping Completion) {
        guard let window else { return completion(nil, nil) }
        // Base64 inflates by 4/3; reject oversized strings before decoding.
        // utf8.count is O(1) for native strings (count walks every character),
        // and base64 is ASCII, so both give the same number.
        guard let contents, !contents.isEmpty, contents.utf8.count <= HostLimits.maxBackupBytes * 2,
              let bytes = Data(base64Encoded: contents) else {
            return completion(nil, HostError("The patch ZIP is empty or too large."))
        }
        // 22 bytes is the smallest valid ZIP (end-of-central-directory record);
        // "PK\u{3}\u{4}" is the local file header signature the editor writes first.
        guard bytes.count >= 22, bytes.count <= HostLimits.maxBackupBytes, bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
            return completion(nil, HostError("The editor did not create a valid patch ZIP."))
        }
        let panel = NSSavePanel()
        panel.title = "Save patch"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        // Keep only the file-name part of what the page suggests. An empty name
        // must not reach URL(fileURLWithPath:), which would resolve it to the
        // current directory and suggest that folder's name instead.
        let suggested = (name ?? "") as NSString
        panel.nameFieldStringValue = suggested.length == 0 ? "Ocarina-of-Time-Patch.zip" : suggested.lastPathComponent
        if let lastFolder { panel.directoryURL = lastFolder.deletingLastPathComponent() }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return completion(nil, nil) }
            // Write off the main actor (like Task.Run in Program.cs) so a slow
            // external or network disk does not freeze the window.
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    // .atomic writes a temp file and renames it, like WritePatch.
                    Result { try bytes.write(to: url, options: .atomic) }
                }.value
                switch outcome {
                case .success: completion(url.lastPathComponent, nil)
                case .failure(let error): completion(nil, error)
                }
            }
        }
    }

    private func saveFolder(entries: [[String: String]]?, name: String?, completion: @escaping Completion) {
        guard let name else { return completion(nil, HostError("Invalid patch folder name.")) }
        let files: [String: Data]
        do { files = try PatchFolderWriter.decode(entries, name: name) }
        catch { return completion(nil, error) }
        let panel = NSOpenPanel()
        panel.message = "Select where to create the patch folder"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = lastFolder?.deletingLastPathComponent()
        activePanel = panel
        panel.begin { [weak self] response in
            self?.activePanel = nil
            guard response == .OK, let folder = panel.url else { return completion(nil, nil) }
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    Result { try PatchFolderWriter.write(parent: folder, files: files, name: name) }
                }.value
                switch outcome {
                case .success(let url): completion(url.path, nil)
                case .failure(let error): completion(nil, error)
                }
            }
        }
    }

    // MARK: Window events

    /// Keeps the folder panel in front: clicking the editor window while it
    /// is open would otherwise hide it behind, with the page's button disabled.
    func windowDidBecomeKey(_ notification: Notification) {
        if let activePanel, activePanel.isVisible {
            activePanel.makeKeyAndOrderFront(nil)
        }
    }

    /// Finishes a layout change that had to wait for full screen to end.
    func windowDidExitFullScreen(_ notification: Notification) {
        applyLayout(loaded: workspaceLoaded)
    }

    // MARK: Navigation lockdown

    /// Allows only the initial in-memory page (and its #fragments), like the
    /// NavigationStarting filter in Program.cs.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        var withoutFragment = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        withoutFragment?.fragment = nil
        decisionHandler(withoutFragment?.url == pageURL ? .allow : .cancel)
    }

    /// Runs when a new page starts (first load, crash recovery, or a reload
    /// from anywhere). The new page starts on its landing view with fresh
    /// request ids, so drop replies meant for the old page and shrink the
    /// window back to the landing size. Same-page #fragment jumps don't
    /// commit, so they don't come here.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageGeneration += 1
        if workspaceLoaded {
            workspaceLoaded = false
            applyLayout(loaded: false)
        }
    }

    /// Recovers from a crashed or killed web content process (for example
    /// under memory pressure), which would otherwise leave a blank window.
    /// In-memory edits are gone at that point, so say so, then reload the
    /// editor; didCommit resets the window to its landing state.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let window {
            let alert = NSAlert()
            alert.messageText = "The editor stopped unexpectedly."
            alert.informativeText = "Unsaved edits were lost. Open the backup again to continue."
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
        loadEditor()
    }

    /// Blocks pop-up windows (target=_blank, window.open).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    /// Reports a page that failed to load and closes the window.
    private func showFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "The editor window could not start."
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        close()
    }
}
