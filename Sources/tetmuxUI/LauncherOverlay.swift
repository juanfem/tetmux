import SwiftUI

public struct LauncherItem: Identifiable {
    public let id = UUID()
    public let title: String
    public let subtitle: String
    public let iconName: String
    /// F4.26 — items for unreachable hosts stay listed, greyed, and connect on selection.
    public let isAvailable: Bool
    public let action: () -> Void

    public init(
        title: String,
        subtitle: String,
        iconName: String,
        isAvailable: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.isAvailable = isAvailable
        self.action = action
    }
}

/// F4.25 — one overlay over hosts, sessions, and windows.
struct LauncherOverlay: View {
    @Binding var isPresented: Bool
    let items: [LauncherItem]

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isSearchFocused: Bool
    /// §7 — Reduce Motion. The list still scrolls to the selection; it just stops sliding there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var matches: [LauncherItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items
            .compactMap { item -> (LauncherItem, Int)? in
                guard let score = Self.score(trimmed, in: "\(item.title) \(item.subtitle)") else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search hosts, sessions, and windows", text: $query)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .focused($isSearchFocused)
                            .onSubmit { activate() }
                            .onChange(of: query) { _, _ in selection = 0 }
                    }
                    .padding(12)

                    Divider()

                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                    row(item, isSelected: index == selection)
                                        .id(index)
                                        .onTapGesture {
                                            selection = index
                                            activate()
                                        }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selection) { _, new in
                            withAnimation(reduceMotion ? nil : .linear(duration: 0.08)) {
                                scroll.scrollTo(new)
                            }
                        }
                    }
                }
                .frame(width: 560)
                .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
                .shadow(radius: 24)
            }
            .onAppear {
                query = ""
                selection = 0
                isSearchFocused = true
            }
            .onExitCommand { dismiss() }
            .background {
                // Arrow keys without stealing them from the search field.
                Group {
                    Button("") { selection = min(selection + 1, max(matches.count - 1, 0)) }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button("") { selection = max(selection - 1, 0) }
                        .keyboardShortcut(.upArrow, modifiers: [])
                }
                .opacity(0)
            }
        }
    }

    private func row(_ item: LauncherItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .frame(width: 20)
                .foregroundStyle(item.isAvailable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).fontWeight(.medium)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(item.isAvailable ? 1 : 0.55)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private func activate() {
        guard matches.indices.contains(selection) else { return }
        matches[selection].action()
        dismiss()
    }

    private func dismiss() {
        isPresented = false
        query = ""
    }

    /// Subsequence match, scoring runs of adjacent characters and word-start hits higher — enough
    /// to make "dbw" find "devbox › web" without a ranking library.
    static func score(_ needle: String, in haystack: String) -> Int? {
        let target = Array(haystack.lowercased())
        let pattern = Array(needle.lowercased().filter { !$0.isWhitespace })
        guard !pattern.isEmpty else { return 0 }

        var score = 0
        var targetIndex = 0
        var lastMatch = -2
        for character in pattern {
            var found = false
            while targetIndex < target.count {
                if target[targetIndex] == character {
                    if targetIndex == lastMatch + 1 { score += 6 }
                    if targetIndex == 0 || target[targetIndex - 1] == " " || target[targetIndex - 1] == "-" {
                        score += 4
                    }
                    score += 1
                    lastMatch = targetIndex
                    targetIndex += 1
                    found = true
                    break
                }
                targetIndex += 1
            }
            if !found { return nil }
        }
        return score
    }
}
