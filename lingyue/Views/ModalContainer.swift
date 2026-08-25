import SwiftUI

enum ModalStyle {
    static let presentationAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.84)

    /// Composite transition call sites attach to a whole overlay (scrim + card).
    /// A plain fade with its own fast curves: the scrim must never scale — a
    /// scaled full-screen dim pulls its edges into view mid-flight. The card's
    /// pop lives in `cardTransition`, which the containers apply to the card
    /// layer alone; both run when the overlay branch is inserted or removed.
    static let transition: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.22)),
        removal: .opacity.animation(.easeOut(duration: 0.18))
    )

    /// Card layer: springs in with a touch of overshoot; exits quickly and
    /// without bounce, sinking slightly as it fades so dismissal reads as the
    /// card settling away rather than the spring played backwards. The exit
    /// finishes just before the scrim's fade so the dim never outlines an
    /// already-empty screen.
    static let cardTransition: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.86)
            .combined(with: .opacity)
            .animation(.spring(response: 0.38, dampingFraction: 0.72)),
        removal: .scale(scale: 0.93)
            .combined(with: .offset(y: 8))
            .combined(with: .opacity)
            .animation(.easeIn(duration: 0.16))
    )
}

struct ModalContainer<Content: View>: View {
    let dismissOnTapOutside: Bool
    let onDismiss: () -> Void
    let content: Content

    init(
        dismissOnTapOutside: Bool = true,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.dismissOnTapOutside = dismissOnTapOutside
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.40)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if dismissOnTapOutside { onDismiss() }
                }
                .accessibilityHidden(true)

            content
                .padding(.horizontal, 24)
                .transition(ModalStyle.cardTransition)
        }
        .accessibilityAddTraits(.isModal)
    }
}

struct ModalCard<Content: View>: View {
    var maxWidth: CGFloat = 360
    var horizontalPadding: CGFloat = 22
    var verticalPadding: CGFloat = 22
    var cornerRadius: CGFloat = 22
    let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme

    init(
        maxWidth: CGFloat = 360,
        horizontalPadding: CGFloat = 22,
        verticalPadding: CGFloat = 22,
        cornerRadius: CGFloat = 22,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.40 : 0.14),
                radius: 24, x: 0, y: 12
            )
    }

    private var cardBackground: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            theme.cardBackground.opacity(colorScheme == .dark ? 0.18 : 0.55)

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.20),
                    Color.white.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .center
            )
            .blendMode(.softLight)
        }
    }
}

enum ModalButtonRole {
    case primary
    case secondary
    case destructive
}

struct ModalButton: View {
    let title: String
    let role: ModalButtonRole
    let action: () -> Void
    var isDisabled: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme
    @ScaledMetric(relativeTo: .callout) private var minHeight: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .background(backgroundLayer)
                .overlay {
                    if role == .secondary {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10),
                                lineWidth: 1
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(isDisabled ? 0.45 : 1.0)
                .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .buttonStyle(ModalPressableButtonStyle())
    }

    private var foregroundColor: Color {
        switch role {
        case .primary: return Color.white
        case .secondary: return Color.primary
        case .destructive: return Color.white
        }
    }

    private var destructiveColor: Color {
        Color(red: 0.90, green: 0.45, blue: 0.45)
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        switch role {
        case .primary:
            LinearGradient(
                colors: [
                    theme.accent,
                    theme.accent.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .secondary:
            Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.04)
        case .destructive:
            LinearGradient(
                colors: [
                    destructiveColor,
                    destructiveColor.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct ModalPressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
