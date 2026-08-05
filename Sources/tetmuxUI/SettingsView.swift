import AppKit
import SwiftUI
import tetmuxCore

/// The settings pane `TerminalTheme` was always documented as waiting for.
///
/// Deliberately small. §1.2 rules out being a general-purpose terminal emulator, so this is not a
/// profile editor: it holds the settings whose absence was actually felt — the font, which is the
/// most-adjusted setting in any terminal, and the scrollback depth, which decided whether scrolling
/// up found anything at all.
struct SettingsView: View {
    @Bindable var model: AppModel

    private static let scrollbackChoices = [1_000, 5_000, 10_000, 50_000, 100_000]

    var body: some View {
        TabView {
            terminal.tabItem { Label("Terminal", systemImage: "terminal") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
            KeymapSettingsView(model: model).tabItem { Label("Keys", systemImage: "keyboard") }
        }
        .frame(width: 460)
        .padding(20)
    }

    private var terminal: some View {
        Form {
            Section {
                Picker("Font", selection: $model.theme.fontName) {
                    ForEach(Self.monospacedFontNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                LabeledContent("Size") {
                    HStack {
                        Slider(
                            value: $model.theme.fontSize,
                            in: TerminalTheme.fontSizeRange,
                            step: 1
                        )
                        Text("\(Int(model.theme.fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                // T5.8 — off by default, and now actually reachable.
                Toggle("Font ligatures", isOn: $model.theme.ligatures)
            } header: {
                Text("Font")
            } footer: {
                // Worth saying, because it is the one setting here that costs a round trip: the grid
                // is derived from the cell size, so every pane on screen is resized through tmux.
                Text("Changing the font re-asks tmux for a new grid, so panes will reflow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Scrollback", selection: $model.theme.scrollbackLines) {
                    ForEach(Self.scrollbackChoices, id: \.self) { lines in
                        Text("\(lines.formatted()) lines").tag(lines)
                    }
                }
            } footer: {
                Text(
                    "Held by tetmux, not by tmux: control mode streams output here, so this is what "
                    + "scrolling up searches."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// F4.31 — which events are worth interrupting the user for.
    ///
    /// Two toggles rather than a per-host or per-window matrix: the *scope* of activity notifications
    /// is already expressed by which windows are watched, which is a per-window decision made where
    /// the window is (its context menu), not in a list here that would have to be kept in step with a
    /// tree that changes every minute.
    private var notifications: some View {
        Form {
            Section {
                Toggle("Bell", isOn: $model.notifications.bells)
                Toggle("Activity in watched windows", isOn: $model.notifications.activity)
            } header: {
                Text("Notify me about")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Only while tetmux is in the background — a window you are looking at needs no banner.")
                    Text(
                        "Watch a window from its tab or its row in the tree. Activity is output "
                        + "arriving in a window nobody is reading, which is what a long job that "
                        + "prints and never rings looks like."
                    )
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if !model.watchedWindows.isEmpty {
                Section("Watched windows") {
                    ForEach(watchedRows, id: \.id) { row in
                        LabeledContent(row.label) {
                            Button("Stop Watching") {
                                model.toggleWatch(hostId: row.hostId, windowId: row.windowId)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The watched windows, named the way the tree names them.
    ///
    /// A watch outlives the window it names — quitting tetmux does not stop tmux, and a window can be
    /// closed from anywhere — so a row whose window is no longer in the topology is shown by its id
    /// rather than dropped. Hiding it would leave the user with a list that disagrees with the count
    /// and no way to clear an entry they can see the effect of.
    private var watchedRows: [(id: String, hostId: String, windowId: String, label: String)] {
        model.watchedWindows
            .sorted { ($0.hostId, $0.windowId) < ($1.hostId, $1.windowId) }
            .map { watch in
                let host = model.hosts.first { $0.id == watch.hostId }
                let window = host?.window(watch.windowId)
                let name = window?.displayLabel ?? watch.windowId
                return (
                    id: "\(watch.hostId)\u{1}\(watch.windowId)",
                    hostId: watch.hostId,
                    windowId: watch.windowId,
                    label: "\(host?.config.name ?? watch.hostId) — \(name)"
                )
            }
    }

    /// Monospaced faces only. A proportional font in a terminal is not a preference, it is a bug, and
    /// the whole cell-size derivation in `TerminalTheme` assumes a fixed advance.
    private static let monospacedFontNames: [String] = {
        let names = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        // Always offer the default, even on a system where it fails the check above.
        return Array(Set(names).union([TerminalTheme.default.fontName])).sorted()
    }()
}
