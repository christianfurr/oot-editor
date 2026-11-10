import Darwin
import Foundation

enum SaveApply {
    static func apply(_ entries: [[String: String]], to account: URL, backups: URL) throws -> String {
        let fm = FileManager.default
        let paths = entries.compactMap { $0["path"] }
        guard (2...3).contains(paths.count), paths.count == entries.count, Set(paths).count == paths.count,
              let progress = paths.first(where: { $0.hasSuffix("/progress.sav") }),
              progress.range(of: #"\Aslot_0[0-5]/progress\.sav\z"#, options: .regularExpression) != nil else {
            throw HostError("Open a numbered MacNativeGames save slot before applying.")
        }
        let caption = String(progress.dropLast("progress.sav".count)) + "caption.sav"
        let required: Set<String> = [progress, caption]
        guard required.isSubset(of: Set(paths)), Set(paths).isSubset(of: required.union(["option.sav"])) else {
            throw HostError("The edit must contain one matching progress and caption pair.")
        }
        guard account.standardizedFileURL.path == account.resolvingSymlinksInPath().path else {
            throw HostError("The profile path must point directly to the save account.")
        }
        var replacements: [String: Data] = [:]
        for (entry, path) in zip(entries, paths) {
            guard let before = entry["before"], let after = entry["after"],
                  before.utf8.count <= 3_000_000, after.utf8.count <= 3_000_000,
                  let original = Data(base64Encoded: before), let edited = Data(base64Encoded: after),
                  original.starts(with: [4, 3, 2, 1]), edited.count == original.count,
                  edited.prefix(12) == original.prefix(12) else {
                throw HostError("The edit contains an invalid save file.")
            }
            let file = account.appending(path: path)
            guard file.path == file.resolvingSymlinksInPath().path,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, values.fileSize == original.count,
                  try Data(contentsOf: file) == original else {
                throw HostError("The destination save changed. Open a fresh copy before applying edits.")
            }
            if original != edited { replacements[path] = edited }
        }
        guard !replacements.isEmpty else { return "No save changes to apply." }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = backups.appending(path: "Before Apply \(stamp)-\(UUID().uuidString.prefix(6))")
        let backupSave = backup.appending(path: "save")
        let staged = account.deletingLastPathComponent().appending(path: ".oot-editor-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try fm.createDirectory(at: backupSave, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: account, to: backupSave.appending(path: account.lastPathComponent))
        } catch {
            try? fm.removeItem(at: backup)
            throw error
        }
        try fm.copyItem(at: account, to: staged)
        for (path, data) in replacements {
            try data.write(to: staged.appending(path: path), options: .atomic)
        }
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, account.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return "Applied. Backup: \(backup.lastPathComponent). Reopen the save before editing again."
    }
}
