import AppKit
import Darwin
import SwiftUI

private let gameID = "org.macnativegames.oot"
private let gameApp = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Ocarina of Time.app")
private let fm = FileManager.default
private let home = fm.homeDirectoryForCurrentUser
private let support = home.appending(path: "Library/Application Support/MacNativeGames")
private let profile = support.appending(path: "OcarinaOfTime/profile")
private let editorData = home.appending(path: "Library/Application Support/OoT Editor")

private struct GameNotice: LocalizedError {
    var text: String
    var errorDescription: String? { text }
}

@main struct OoTEditor: App {
    var body: some Scene {
        WindowGroup("OoT Editor") { EditorView() }
            .defaultSize(width: 650, height: 545)
            .windowResizability(.contentSize)
    }
}

private struct EditorView: View {
    @State private var message = "Changes to the player profile take effect on the next launch."
    @State private var canvas = 2
    @State private var upscaler = 1
    @State private var frame = "off"
    @State private var running = false
    @State private var busy = false
    @State private var workshop: EditorWindowController?
    @State private var liveInput: URL?
    @State private var livePID: pid_t?
    @State private var song = 0
    @State private var playingSong = false
    @State private var supportsLiveOcarina = false

    private let canvasNames = ["720p from 480p", "720p native", "1080p from 720p", "1080p native",
                               "1440p from 1080p", "1440p native"]
    private let limits = [30, 40, 60, 72, 90, 120]
    // Switch default note layout, sent as the runtime’s fixed Mac keycodes.
    private let liveSongs: [(label: String, notes: [Int])] = [
        ("Summon Epona", [34, 32, 38, 34, 32, 38]),
        ("Skip to Day or Night", [38, 14, 34, 38, 14, 34]),
        ("Warp to Sacred Forest Meadow", [12, 34, 32, 38, 32, 38]),
        ("Warp to Death Mountain Crater", [14, 12, 14, 12, 38, 14, 38, 14]),
        ("Warp to Lake Hylia", [12, 14, 38, 38, 32]),
        ("Warp to the Graveyard", [32, 38, 38, 12, 32, 38, 14]),
        ("Warp to Desert Colossus", [12, 14, 12, 38, 14, 12]),
        ("Warp to the Temple of Time", [34, 38, 34, 38, 32, 34]),
    ]
    private let interpolationNames = ["30+30 FPS", "40+40 FPS", "50+50 FPS", "Uncapped interpolation", "60+60 FPS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 13) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 29)).foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ocarina of Time").font(.system(.largeTitle, design: .serif).weight(.semibold))
                    Text("MacNativeGames · Switch 2 · 131072").foregroundStyle(.secondary)
                }
                Spacer()
                Label(running ? "Game running" : "Game closed", systemImage: running ? "play.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Player graphics") {
                Form {
                    Picker("Resolution", selection: $canvas) {
                        ForEach(canvasNames.indices, id: \.self) { Text(canvasNames[$0]).tag($0) }
                    }
                    Picker("Upscaler", selection: $upscaler) {
                        Text("Game’s own").tag(0)
                        Text("MetalFX").tag(1)
                    }
                    Picker("Frame mode", selection: $frame) {
                        Text("Uncapped").tag("off")
                        ForEach(limits, id: \.self) { Text("\($0) FPS").tag("lock-\($0)") }
                        Divider()
                        ForEach(interpolationNames.indices, id: \.self) {
                            Text(interpolationNames[$0]).tag("interp-\($0 + 1)")
                        }
                    }
                }
                .padding(8)
                HStack {
                    Spacer()
                    Button("Save Graphics Settings") { perform(saveGraphics) }
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
            }
            .disabled(running || busy)
            GroupBox("Playtest") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick Start uses a separate test profile. Continue resumes its checkpoint. New Game uses the shortened opening.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Open Player Save Folder") { reveal(profile.appending(path: "save")) }
                        Button("Back Up Player Save") { perform(backup) }.disabled(running || busy)
                        Spacer()
                        Button("Quick Start", systemImage: "play.fill") { launchGame(test: true) }
                            .buttonStyle(.borderedProminent).disabled(running || busy)
                    }
                }.padding(8)
            }
            GroupBox("Save Workshop") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Edit equipment, supplies, health and progression. Apply with a backup, or export a folder or ZIP.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Edit Test Save…") { showWorkshop(testProfile, target: testProfile, label: "Test Profile") }
                        Button("Edit Player Save Copy…") { openPlayerCopy() }.disabled(running || busy)
                        Spacer()
                        Button("Open Backups") { reveal(editorData.appending(path: "Backups")) }
                    }
                }.padding(8)
            }
            GroupBox("Live Ocarina") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(supportsLiveOcarina
                         ? "Launch here, learn the song, then open the ocarina in-game with Left on the D-pad. Use the default note layout."
                         : "Live songs require a native OoT runtime with the SDK 22 vibration fix.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Launch Player") { launchGame(test: false) }.disabled(running || busy)
                        Picker("Song", selection: $song) {
                            ForEach(liveSongs.indices, id: \.self) { Text(liveSongs[$0].label).tag($0) }
                        }
                        Button("Play Song") { playSong() }.disabled(!supportsLiveOcarina || !running || livePID == nil || playingSong)
                    }
                }.padding(8)
            }
            Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 650)
        .preferredColorScheme(.dark)
        .tint(.yellow)
        .task {
            loadSettings()
            while !Task.isCancelled {
                running = isRunning
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: running) { _, active in
            if !active {
                loadSettings()
                if let liveInput { try? fm.removeItem(at: liveInput) }
                liveInput = nil
                livePID = nil
            }
        }
    }

    private var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: gameID).isEmpty }

    private func read(_ name: String) -> String? {
        (try? String(contentsOf: profile.appending(path: name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadSettings() {
        supportsLiveOcarina = Self.checkLiveOcarinaSupport()
        if let value = read("graphics-canvas.txt").flatMap(Int.init), canvasNames.indices.contains(value) { canvas = value }
        if let value = read("graphics-net-bypass.txt").flatMap(Int.init), (0...1).contains(value) { upscaler = value }
        if let value = read("graphics-frame.txt"), value == "off"
            || limits.contains(where: { value == "lock-\($0)" })
            || interpolationNames.indices.contains(where: { value == "interp-\($0 + 1)" }) {
            frame = value
        }
    }

    private func perform(_ operation: () throws -> String) {
        do { message = try operation() }
        catch { message = error.localizedDescription }
    }

    private func withClosedGame<T>(_ operation: () throws -> T) throws -> T {
        guard !isRunning else { throw GameNotice(text: "Quit OoT before changing or backing up the player profile.") }
        let slot = support.appending(path: "TOTK/game-slot")
        try fm.createDirectory(at: slot, withIntermediateDirectories: true)
        let fd = open(slot.appending(path: "lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw GameNotice(text: "Could not open the native game lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, !isRunning else {
            throw GameNotice(text: "A MacNativeGames session is using the game lock. Quit it before making changes.")
        }
        return try operation()
    }

    private func saveGraphics() throws -> String {
        try withClosedGame {
            try fm.createDirectory(at: profile, withIntermediateDirectories: true)
            for (name, value) in [("graphics-canvas.txt", String(canvas)), ("graphics-net-bypass.txt", String(upscaler)),
                                  ("graphics-frame.txt", frame)] {
                try Data((value + "\n").utf8).write(to: profile.appending(path: name), options: .atomic)
            }
            return "Saved. These settings apply the next time you open OoT."
        }
    }

    private func backup() throws -> String {
        let copy = try withClosedGame { try createBackup() }
        reveal(copy)
        return "Player save backed up."
    }

    private func createBackup() throws -> URL {
        let save = profile.appending(path: "save")
        let files = fm.enumerator(at: save, includingPropertiesForKeys: [.isRegularFileKey])
        let hasSave = files?.compactMap { $0 as? URL }.contains {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        } ?? false
        guard hasSave else { throw GameNotice(text: "Create a player save in OoT first.") }
        let snapshots = editorData.appending(path: "Backups")
        try fm.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let copy = snapshots.appending(path: "\(stamp)-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: copy, withIntermediateDirectories: false)
        do {
            try fm.copyItem(at: save, to: copy.appending(path: "save"))
            let users = profile.appending(path: "users.txt")
            if fm.fileExists(atPath: users.path) { try fm.copyItem(at: users, to: copy.appending(path: "users.txt")) }
        } catch {
            try? fm.removeItem(at: copy)
            throw error
        }
        return copy
    }

    private var testProfile: URL { editorData.appending(path: "Test Profile") }

    private func saveAccount(in root: URL) -> URL {
        let save = root.appending(path: "save")
        let accounts = (try? fm.contentsOfDirectory(at: save, includingPropertiesForKeys: nil)) ?? []
        let candidates = accounts.filter { account in
            (0..<6).contains { index in
                let slot = account.appending(path: String(format: "slot_%02d", index))
                return fm.fileExists(atPath: slot.appending(path: "progress.sav").path)
                    && fm.fileExists(atPath: slot.appending(path: "caption.sav").path)
            }
        }
        return candidates.count == 1 ? candidates[0] : save
    }

    private func focusOpenWorkshop() -> Bool {
        guard let window = workshop?.window, window.isVisible || window.isMiniaturized else { return false }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        message = "Save Workshop is already open. Close that window to start editing a different copy."
        return true
    }

    private func showWorkshop(_ root: URL, target: URL, label: String) {
        guard !focusOpenWorkshop() else { return }
        let folder = saveAccount(in: root)
        let account = saveAccount(in: target)
        let hasSingleAccount = account.deletingLastPathComponent().path == target.appending(path: "save").path
        let editor = EditorWindowController(defaultFolder: folder, profileName: hasSingleAccount ? label : nil) { edits in
            try withClosedGame {
                try SaveApply.apply(edits, to: account, backups: editorData.appending(path: "Backups"))
            }
        }
        workshop = editor
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    private func openPlayerCopy() {
        guard !focusOpenWorkshop() else { return }
        do {
            let copy = try withClosedGame { try createBackup() }
            showWorkshop(copy, target: profile, label: "Player Profile")
            message = "Created a copy. Choose Open Backup in Save Workshop to load it."
        } catch {
            message = error.localizedDescription
        }
    }

    private func reveal(_ url: URL) {
        guard fm.fileExists(atPath: url.path) else { message = "That folder will appear after the first launch."; return }
        NSWorkspace.shared.open(url)
    }

    private static func checkLiveOcarinaSupport() -> Bool {
        let runtime = gameApp.appending(path: "Contents/MacOS/OcarinaOfTime")
        let lookup = Data("_ZN2nn3hid29IsOunceVibrationDeviceMountedERKNS0_21VibrationDeviceHandleE\0".utf8)
        return (try? Data(contentsOf: runtime, options: .mappedIfSafe).range(of: lookup)) != nil
    }

    private func launchGame(test: Bool) {
        guard !isRunning else { message = "Quit the current game before starting a test."; return }
        guard let bundle = Bundle(url: gameApp), bundle.bundleIdentifier == gameID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "131072" else {
            message = "Install the MacNativeGames OoT 131072 app in your Applications folder first."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        let input = editorData.appending(path: "input-\(UUID().uuidString).txt")
        configuration.environment = ["TOTK_INPUT_FILE": input.path]
        if test {
            configuration.environment.merge([
                "OOT_AUTO_SKIP_OPENING": "1", "TOTK_PROFILE_DIR": testProfile.path,
                "TOTK_CLOUD_SAVE_DIR": "0", "TOTK_ROMFS_MODS": "0",
            ]) { _, new in new }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try withClosedGame { "" }
                try fm.createDirectory(at: editorData, withIntermediateDirectories: true)
                try Data().write(to: input, options: .withoutOverwriting)
                let application = try await NSWorkspace.shared.openApplication(at: gameApp, configuration: configuration)
                liveInput = input
                livePID = application.processIdentifier
                message = test ? "Opened the separate test profile. Choose Continue to resume its checkpoint."
                               : "Opened the player profile with Live Ocarina."
            } catch {
                try? fm.removeItem(at: input)
                message = error.localizedDescription
            }
        }
    }

    private func playSong() {
        guard supportsLiveOcarina, let input = liveInput, let pid = livePID else { return }
        let notes = liveSongs[song].notes
        playingSong = true
        Task {
            defer { playingSong = false }
            do {
                let file = try FileHandle(forWritingTo: input)
                defer { try? file.close() }
                for note in notes {
                    guard livePID == pid, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == gameID else {
                        throw GameNotice(text: "The OoT session ended.")
                    }
                    try file.seekToEnd()
                    try file.write(contentsOf: Data("key \(note) 125\n".utf8))
                    try await Task.sleep(for: .milliseconds(250))
                }
                message = "Sent the song. Confirm any warp prompt in OoT."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
