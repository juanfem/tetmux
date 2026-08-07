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

    /// The estimate, in the units somebody thinking about memory thinks in.
    ///
    /// `.memory` rather than a hand-rolled division: it is the formatter macOS uses everywhere else
    /// for this, so "18 MB" here reads the same as it does in Activity Monitor, which is where
    /// anybody checking this claim will go next.
    private static func scrollbackFootprint(_ theme: TerminalTheme) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(theme.estimatedScrollbackBytesPerPane()), countStyle: .memory
        )
    }

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
                Picker("Colours", selection: $model.theme.colorSchemeId) {
                    ForEach(TerminalColorScheme.all) { scheme in
                        Text(scheme.name).tag(scheme.id)
                    }
                }
                SchemePreview(scheme: model.theme.colorScheme)
            } header: {
                Text("Colours")
            } footer: {
                // §7's line, stated where somebody is about to wonder why the tab bar did not change.
                Text(
                    "Applies to what programs draw inside a pane. The window, tabs and tree keep "
                    + "following the system appearance, and System does the same for panes."
                )
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
                // The cost goes beside the choice, because it is the whole of what makes this a
                // choice. The picker offers 100 000 lines, which is ten times the default and is
                // paid *per pane*: at twenty panes that is gigabytes, and nothing else in the app
                // tells anybody so. P6.7 is this number multiplied by the panes on screen.
                Text(
                    "Held by tetmux, not by tmux: control mode streams output here, so this is what "
                    + "scrolling up searches.\n\n"
                    + "About \(Self.scrollbackFootprint(model.theme)) per pane at 80 columns, and "
                    + "every pane on screen keeps its own. Lower this if you work with many panes "
                    + "open."
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
                Toggle("Activity in watched tabs", isOn: $model.notifications.activity)
            } header: {
                Text("Notify me about")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Only while tetmux is in the background — a tab you are looking at needs no banner.")
                    Text(
                        "Watch a tab from the tab strip or its row in the tree. Activity is output "
                        + "arriving in a tab nobody is reading, which is what a long job that "
                        + "prints and never rings looks like."
                    )
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if !model.watchedWindows.isEmpty {
                Section("Watched tabs") {
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

/// The sixteen ANSI slots and the two that are not, drawn as they will look.
///
/// A scheme is a list of colours, and a list of colour *names* tells nobody anything — the whole
/// question a person is asking is "what will my terminal look like". Two rows of eight, in the order
/// programs address them, plus the foreground on the background so the pairing that matters most is
/// the one shown largest.
struct SchemePreview: View {
    let scheme: TerminalColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Aa  the quick brown fox")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color(nsColor: foreground))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: background)))

            HStack(spacing: 3) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, colour in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: colour))
                        .frame(height: 12)
                }
            }
        }
        .padding(.vertical, 2)
        // One element: a row of eighteen unlabelled colours read aloud one at a time is noise, and
        // the name is already on the picker beside it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the \(scheme.name) colours")
    }

    /// System has no palette of its own — it *is* the current appearance — so the preview asks the
    /// same colours the pane will, rather than showing a fixed light-mode copy of them.
    private var foreground: NSColor {
        scheme.followsSystemAppearance ? .textColor : scheme.foreground.nsColor
    }

    private var background: NSColor {
        scheme.followsSystemAppearance ? .textBackgroundColor : scheme.background.nsColor
    }

    private var swatches: [NSColor] {
        (scheme.followsSystemAppearance ? TerminalColorScheme.defaultAnsi : scheme.ansi).map(\.nsColor)
    }
}
