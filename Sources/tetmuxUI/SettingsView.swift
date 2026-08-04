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
