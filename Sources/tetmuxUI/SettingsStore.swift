import Foundation
import tetmuxCore

/// `settings.json` beside `hosts.json` and `workspace.json` (§2.3).
///
/// It holds the **keymap** and nothing else, which wants saying because the terminal's appearance
/// lives in `UserDefaults` and stays there. The two are different kinds of preference: font, size,
/// ligatures and scrollback are ordinary macOS application settings that the system already has a
/// right place for, while a keymap is a document — a table someone may well want to read, diff, copy
/// to another Mac, or write by hand, which is exactly the argument §2.3 makes for JSON over a
/// database. Moving the appearance here would buy nothing and would break the one thing about it
/// that is already right.
public actor SettingsStore {
    private let storeURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? HostConfigStore.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = base.appendingPathComponent("settings.json")
    }

    /// The file's shape. One key so far; a struct rather than a bare map so adding a second setting
    /// does not change the format of the first.
    private struct Contents: Codable {
        var keymap: [String: String?]?
    }

    /// The stored keymap overrides, empty when there is no file or it cannot be read.
    ///
    /// An unreadable `settings.json` is *not* moved aside the way `hosts.json` is. That one is
    /// irreplaceable — a list of machines somebody typed in — and this one is a handful of chords
    /// that fall back to a documented default. Failing quietly to the defaults is the behaviour with
    /// the smaller surprise.
    public func keymapOverrides() -> [String: String?] {
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else { return [:] }
        return (try? JSONDecoder().decode(Contents.self, from: data))?.keymap ?? [:]
    }

    public func saveKeymapOverrides(_ overrides: [String: String?]) {
        // Read-modify-write, so a setting added later is not erased by a keymap change.
        var contents = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }
            ?? Contents()
        contents.keymap = overrides.isEmpty ? nil : overrides

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(contents) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
