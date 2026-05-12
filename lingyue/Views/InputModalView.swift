import SwiftUI

struct InputModalView: View {
    let title: String
    let helperText: String?
    let placeholder: String
    @Binding var text: String
    let confirmTitle: String
    let cancelTitle: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme

    init(
        title: String,
        helperText: String? = nil,
        placeholder: String,
        text: Binding<String>,
        confirmTitle: String = "添加",
        cancelTitle: String = "取消",
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.helperText = helperText
        self.placeholder = placeholder
        self._text = text
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
    }

    static var presentationAnimation: Animation { ModalStyle.presentationAnimation }
    static var transition: AnyTransition { ModalStyle.transition }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ModalContainer(dismissOnTapOutside: true, onDismiss: onDismiss) {
            ModalCard {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let helperText, !helperText.isEmpty {
                            Text(helperText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        TextField(placeholder, text: $text)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body)
                            .foregroundStyle(.primary)
                            .tint(theme.accent)
                            .padding(.vertical, 8)
                            .onSubmit(submitIfPossible)

                        Rectangle()
                            .fill(
                                fieldFocused
                                    ? theme.accent.opacity(0.55)
                                    : Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.14)
                            )
                            .frame(height: 1)
                            .animation(.easeInOut(duration: 0.18), value: fieldFocused)
                    }

                    HStack(spacing: 10) {
                        ModalButton(title: cancelTitle, role: .secondary, action: onDismiss)
                        ModalButton(
                            title: confirmTitle,
                            role: .primary,
                            action: submitIfPossible,
                            isDisabled: trimmedText.isEmpty
                        )
                    }
                }
            }
        }
        .onAppear {
            // Next-runloop focus instead of a hard-coded 180ms delay so the
            // keyboard rises concurrently with the modal's entrance — the old
            // delay made the tap feel laggy ("卡卡的").
            DispatchQueue.main.async {
                fieldFocused = true
            }
        }
    }

    private func submitIfPossible() {
        guard !trimmedText.isEmpty else { return }
        onConfirm()
    }
}

#if DEBUG
private struct InputModalPreviewWrapper: View {
    @State private var name: String = ""

    var body: some View {
        ZStack {
            Color.readerBackground.ignoresSafeArea()
            InputModalView(
                title: "新建分类",
                helperText: "分类会先创建为空，可以稍后加入书籍。",
                placeholder: "分类名称",
                text: $name,
                onConfirm: {},
                onDismiss: {}
            )
        }
    }
}

#Preview("Light") { InputModalPreviewWrapper() }
#Preview("Dark") {
    InputModalPreviewWrapper().preferredColorScheme(.dark)
}
#endif
