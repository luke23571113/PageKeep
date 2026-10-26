import SwiftUI

struct LibrarySearchBar: View {
    @Binding var text: String
    @Binding var focusRequested: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search Notebooks", text: $text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { isFocused = false }
                .accessibilityIdentifier("library.search")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear text")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        .padding(.horizontal, 8)
        .onAppear { isFocused = focusRequested }
        .onChange(of: focusRequested) { _, requested in
            isFocused = requested
        }
    }
}

struct SearchPullState {
    private(set) var distance: CGFloat = 0
    private(set) var isPulling = false
    private(set) var isReady = false
    private var restingPosition: CGFloat?
    private var width: CGFloat = 0

    mutating func updateWidth(_ width: CGFloat) {
        self.width = width
        reset(includingBaseline: true)
    }

    mutating func drag(startX: CGFloat, horizontal: CGFloat, vertical: CGFloat, isEnabled: Bool) {
        isPulling = isEnabled && startX < width - 64 && vertical > 24 && abs(horizontal) < 40
    }

    mutating func updatePosition(_ position: CGFloat?, isEnabled: Bool) {
        guard isEnabled, let position else {
            distance = 0
            return
        }
        guard let restingPosition else {
            self.restingPosition = position
            return
        }
        distance = max(0, position - restingPosition)
        if isPulling && distance >= 72 { isReady = true }
    }

    mutating func release() -> Bool {
        let shouldOpen = isPulling && isReady
        reset()
        return shouldOpen
    }

    mutating func reset(includingBaseline: Bool = false) {
        distance = 0
        isPulling = false
        isReady = false
        if includingBaseline { restingPosition = nil }
    }
}
