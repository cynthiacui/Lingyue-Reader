import SwiftUI

enum CustomAlertType {
    case success
    case error
    case warning
    case info

    var iconName: String {
        switch self {
        case .success: return "checkmark.seal.fill"
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .success: return Color.readerAccent
        case .error: return Color(red: 0.82, green: 0.32, blue: 0.32)
        case .warning: return Color(red: 0.86, green: 0.60, blue: 0.18)
        case .info: return Color(red: 0.34, green: 0.52, blue: 0.74)
        }
    }
}

struct CustomAlertButton {
    let title: String
    let role: ModalButtonRole
    let action: () -> Void

    static func primary(_ title: String, action: @escaping () -> Void) -> CustomAlertButton {
        CustomAlertButton(title: title, role: .primary, action: action)
    }

    static func secondary(_ title: String, action: @escaping () -> Void) -> CustomAlertButton {
        CustomAlertButton(title: title, role: .secondary, action: action)
    }

    static func destructive(_ title: String, action: @escaping () -> Void) -> CustomAlertButton {
        CustomAlertButton(title: title, role: .destructive, action: action)
    }
}

struct CustomAlertView: View {
    let type: CustomAlertType
    let title: String
    let bookTitle: String?
    let message: String
    let primaryButton: CustomAlertButton
    let secondaryButton: CustomAlertButton?
    let onDismiss: (() -> Void)?
    let showsIcon: Bool

    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 30

    init(
        type: CustomAlertType = .info,
        title: String,
        bookTitle: String? = nil,
        message: String,
        primaryButton: CustomAlertButton,
        secondaryButton: CustomAlertButton? = nil,
        showsIcon: Bool = true,
        onDismiss: (() -> Void)? = nil
    ) {
        self.type = type
        self.title = title
        self.bookTitle = bookTitle
        self.message = message
        self.primaryButton = primaryButton
        self.secondaryButton = secondaryButton
        self.showsIcon = showsIcon
        self.onDismiss = onDismiss
    }

    static var presentationAnimation: Animation { ModalStyle.presentationAnimation }
    static var transition: AnyTransition { ModalStyle.transition }

    var body: some View {
        ModalContainer(
            dismissOnTapOutside: onDismiss != nil,
            onDismiss: { onDismiss?() }
        ) {
            ModalCard {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    actions
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsIcon {
                Image(systemName: type.iconName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(type.tintColor)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let bookTitle, !bookTitle.isEmpty {
                    Text("《\(bookTitle)》")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let secondaryButton {
            HStack(spacing: 10) {
                ModalButton(
                    title: secondaryButton.title,
                    role: secondaryButton.role,
                    action: secondaryButton.action
                )
                ModalButton(
                    title: primaryButton.title,
                    role: primaryButton.role,
                    action: primaryButton.action
                )
            }
        } else {
            ModalButton(
                title: primaryButton.title,
                role: primaryButton.role,
                action: primaryButton.action
            )
        }
    }
}

#if DEBUG
#Preview("Light - Success") {
    ZStack {
        Color.readerBackground.ignoresSafeArea()
        CustomAlertView(
            type: .success,
            title: "导入成功",
            bookTitle: "九重紫",
            message: "已加入「玄幻」分类，打开章节时会联网加载正文。",
            primaryButton: .primary("打开阅读") {},
            secondaryButton: .secondary("好的") {},
            onDismiss: {}
        )
    }
}

#Preview("Dark - Error") {
    ZStack {
        Color.black.ignoresSafeArea()
        CustomAlertView(
            type: .error,
            title: "导入失败",
            message: "无法连接到服务器，请检查网络后再试。",
            primaryButton: .primary("好的") {},
            onDismiss: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Replacement - Warning") {
    ZStack {
        Color.readerBackground.ignoresSafeArea()
        CustomAlertView(
            type: .warning,
            title: "替换已有书籍",
            bookTitle: "九重紫",
            message: "已经在书架中。替换会重新导入信息和章节目录。",
            primaryButton: .destructive("替换") {},
            secondaryButton: .secondary("取消") {},
            onDismiss: {}
        )
    }
}
#endif
