import SwiftUI

/// Top-level appearance theme for the app's chrome (Library / Discovery / Settings,
/// tab bar, etc.). Independent of `ReadingTheme`, which controls the reader page surface.
///
/// Add a new theme by appending a case + supplying its color values + background style.
/// Every chrome view reads colors via `@Environment(\.appTheme)`, so no other code
/// changes are needed.
enum AppTheme: String, CaseIterable, Identifiable, Hashable {
    case paperGreen
    case pink
    case leafGreen
    case ink
    case starryNight

    var id: String { rawValue }

    /// Localized label shown in Settings.
    var displayName: String {
        switch self {
        case .paperGreen:  return "纸张"
        case .pink:        return "樱粉"
        case .leafGreen:   return "叶绿"
        case .ink:         return "水墨"
        case .starryNight: return "星夜"
        }
    }

    /// Flat fill color for the page bg. Use this for chip/section backgrounds where a
    /// gradient would be visually noisy. For full-screen chrome backgrounds, render
    /// `ThemeBackgroundView()` instead so the theme can opt into a gradient or pattern.
    var background: Color {
        switch self {
        // Lifted slightly off the 纸张 reading theme (≈#F4F1EB) so the Settings
        // preview card reads as a raised surface instead of melting into the page.
        case .paperGreen:  return Color(red: 0.985, green: 0.978, blue: 0.948)
        case .pink:        return Color(red: 0.99, green: 0.95, blue: 0.95)
        case .leafGreen:   return Color(red: 0.95, green: 0.96, blue: 0.92)
        case .ink:         return Color(red: 0.96, green: 0.94, blue: 0.89) // warm rice paper
        case .starryNight: return Color(red: 0.05, green: 0.07, blue: 0.12)
        }
    }

    /// Style descriptor used by `ThemeBackgroundView`. Gives each theme room to opt into
    /// gradients or decorative patterns without code-side branching at every callsite.
    var backgroundStyle: AppThemeBackground {
        switch self {
        case .paperGreen:
            return .solid(background)
        case .pink:
            return .imagePattern(
                imageName: "PinkBackground",
                gradient: [
                    Color(red: 1.00, green: 0.96, blue: 0.96),
                    Color(red: 0.99, green: 0.93, blue: 0.94),
                    Color(red: 0.98, green: 0.91, blue: 0.92)
                ],
                imageOpacity: 1.0,
                imageScale: 1.0
            )
        case .leafGreen:
            return .imagePattern(
                imageName: "LeafGreenBackground",
                gradient: [
                    Color(red: 0.97, green: 0.98, blue: 0.94),
                    Color(red: 0.94, green: 0.96, blue: 0.91),
                    Color(red: 0.91, green: 0.93, blue: 0.88)
                ],
                imageOpacity: 1.0,
                imageScale: 1.0
            )
        case .ink:
            // Image opacity dialed down so the dramatic ink wash (mountains, fisherman,
            // mist) reads as atmospheric texture rather than foreground; the warm paper
            // gradient warms the otherwise cool grayscale source so it doesn't feel cold.
            return .imagePattern(
                imageName: "InkBackground",
                gradient: [
                    Color(red: 0.97, green: 0.95, blue: 0.91),
                    Color(red: 0.95, green: 0.93, blue: 0.88),
                    Color(red: 0.93, green: 0.91, blue: 0.85)
                ],
                imageOpacity: 0.7,
                imageScale: 1.22
            )
        case .starryNight:
            return .starryNight
        }
    }

    /// Card / pill / surface background — sits one layer above `background`.
    var cardBackground: Color {
        switch self {
        case .paperGreen:  return Color(red: 1.000, green: 0.990, blue: 0.960)
        case .pink:        return Color(red: 1.000, green: 0.957, blue: 0.965) // #FFF4F6
        case .leafGreen:   return Color(red: 0.990, green: 0.992, blue: 0.965)
        case .ink:         return Color(red: 0.99, green: 0.97, blue: 0.93) // soft paper
        case .starryNight: return Color(red: 0.13, green: 0.15, blue: 0.21)
        }
    }

    /// A tinted card surface that sits *darker* than `background` for grouped lists
    /// (e.g. Discovery search results) — gives the card a "recessed" feel rather than
    /// the "raised" feel of `cardBackground`.
    var subtleCardBackground: Color {
        switch self {
        case .paperGreen:  return Color(red: 0.93, green: 0.91, blue: 0.87)
        case .pink:        return Color(red: 0.96, green: 0.90, blue: 0.91)
        case .leafGreen:   return Color(red: 0.90, green: 0.92, blue: 0.86)
        case .ink:         return Color(red: 0.91, green: 0.89, blue: 0.83)
        case .starryNight: return Color(red: 0.10, green: 0.12, blue: 0.18)
        }
    }

    /// Tinted shadow color for raised cards. Pink uses a faint rose halo so cards don't
    /// look like they're shedding flat black ink onto a blush background.
    var cardShadow: Color {
        switch self {
        case .paperGreen:  return Color.black.opacity(0.05)
        case .pink:        return Color(red: 0.55, green: 0.30, blue: 0.36).opacity(0.08)
        case .leafGreen:   return Color(red: 0.30, green: 0.40, blue: 0.28).opacity(0.08)
        case .ink:         return Color(red: 0.18, green: 0.16, blue: 0.14).opacity(0.07)
        // Dark themes barely show shadows; a small black opacity keeps the existing
        // shadow modifiers behaving without making cards look "raised" awkwardly.
        case .starryNight: return Color.black.opacity(0.30)
        }
    }

    /// Interactive accent: tab tint, sliders, primary buttons, selection highlight.
    var accent: Color {
        switch self {
        case .paperGreen:  return Color(red: 0.36, green: 0.43, blue: 0.32)
        case .pink:        return Color(red: 0.78, green: 0.46, blue: 0.54)
        case .leafGreen:   return Color(red: 0.49, green: 0.60, blue: 0.43)
        case .ink:         return Color(red: 0.30, green: 0.28, blue: 0.26) // muted ink gray
        case .starryNight: return Color(red: 0.86, green: 0.74, blue: 0.50) // soft champagne gold
        }
    }

    /// Classical 印章-red used for the 我 hero card's seal badge and streak emphasis.
    /// Dark theme swaps to the gold accent so the seal still reads warm rather than
    /// glaring red against the deep night sky.
    var seal: Color {
        switch self {
        case .paperGreen, .pink, .leafGreen, .ink:
            return Color(red: 0.60, green: 0.24, blue: 0.18)
        case .starryNight:
            return accent
        }
    }

    /// Top → bottom stops for the 我 hero card surface. The card deliberately
    /// does NOT echo the theme hue — instead each theme pairs with a *muted
    /// complement* (or a temperature flip) so the card reads as a distinct,
    /// intentional surface that still sits in harmony: 樱粉(pink)→soft sage,
    /// 叶绿(green)→warm clay, 水墨(cool ink)→warm amber, 纸张(warm cream)→soft
    /// slate-blue, 星夜(cool navy)→warm charcoal. Kept desaturated so the
    /// contrast reads sophisticated, light enough for the dark card text, and
    /// clear of red so the terracotta 灵阅 seal keeps popping.
    /// Kept as a *pale wash* of the complement — light enough not to feel
    /// heavy, but a distinct hue from the themed background so the card still
    /// reads as its own surface (the card shadow does the rest of the lifting).
    var heroGradientStops: [Color] {
        switch self {
        case .starryNight:
            // Soft warm charcoal against the cool navy night sky.
            return [
                Color(red: 0.198, green: 0.184, blue: 0.156),
                Color(red: 0.152, green: 0.140, blue: 0.116)
            ]
        case .paperGreen:
            // Cool complements fought the app's warm palette + terracotta
            // seal, so 纸张 stays warm too: a faint peach/apricot, distinct
            // from its near-white cream background.
            return [
                Color(red: 0.976, green: 0.932, blue: 0.888),
                Color(red: 0.962, green: 0.902, blue: 0.840)
            ]
        case .pink:
            // Blush background → a bright, clean near-white that reads
            // *lighter* than the soft pink behind it (a crisp white card on a
            // colored bg), with only a whisper of warmth so it doesn't go
            // clinical-cold against the warm theme.
            return [
                Color(red: 1.000, green: 0.998, blue: 0.995),
                Color(red: 0.996, green: 0.988, blue: 0.980)
            ]
        case .leafGreen:
            // Green background → faint warm sand (cool ↔ warm).
            return [
                Color(red: 0.974, green: 0.952, blue: 0.916),
                Color(red: 0.956, green: 0.924, blue: 0.866)
            ]
        case .ink:
            // Cool grayscale ink-wash background → faint warm amber.
            return [
                Color(red: 0.977, green: 0.955, blue: 0.895),
                Color(red: 0.963, green: 0.932, blue: 0.844)
            ]
        }
    }

    /// Primary copy: titles, body text in chrome.
    var primaryText: Color {
        switch self {
        case .paperGreen:  return Color(red: 0.11, green: 0.10, blue: 0.09)
        case .pink:        return Color(red: 0.13, green: 0.10, blue: 0.11)
        case .leafGreen:   return Color(red: 0.14, green: 0.16, blue: 0.12)
        case .ink:         return Color(red: 0.13, green: 0.12, blue: 0.11) // dark charcoal
        case .starryNight: return Color(red: 0.94, green: 0.92, blue: 0.85) // warm off-white
        }
    }

    /// Secondary copy: captions, metadata, dividers (often via `.opacity(...)`).
    var secondaryText: Color {
        switch self {
        case .paperGreen:  return Color(red: 0.43, green: 0.39, blue: 0.34)
        case .pink:        return Color(red: 0.50, green: 0.40, blue: 0.42)
        case .leafGreen:   return Color(red: 0.40, green: 0.45, blue: 0.38)
        case .ink:         return Color(red: 0.42, green: 0.40, blue: 0.36)
        case .starryNight: return Color(red: 0.66, green: 0.63, blue: 0.57)
        }
    }

    /// Gradient stops for the Settings picker swatch (top-leading → bottom-trailing).
    /// Most themes lean on `accent` so the swatch hints at the interactive color, but
    /// `.paperGreen` deliberately omits its green accent — that theme's identity is the
    /// paper-like cream chrome, and showing a green corner made the swatch read as "the
    /// green theme" rather than "the paper theme".
    var swatchGradient: [Color] {
        switch self {
        case .paperGreen:
            return [background, cardBackground, subtleCardBackground]
        case .pink, .leafGreen, .ink, .starryNight:
            return [background, cardBackground, accent]
        }
    }

    /// Optional decorative glyph rendered on the Settings theme swatch (e.g. cherry
    /// blossom for Pink). Returning `nil` means the swatch shows just its gradient.
    /// Only consulted when `swatchImageName` is `nil`.
    /// Decorative overlay drawn on top of the gradient swatch in Settings (only used
    /// when `swatchImageName` is `nil`). Each theme owns its own decoration so adding a
    /// new themed glyph doesn't grow a switch in `MeView`.
    @ViewBuilder
    var swatchOverlay: some View {
        switch self {
        case .starryNight:
            SwatchStarsOverlay()
        case .paperGreen, .pink, .leafGreen, .ink:
            EmptyView()
        }
    }

    /// Optional asset image rendered as the Settings theme swatch background. Use this
    /// when the theme has a hand-painted swatch (e.g. cherry-blossom artwork). When
    /// present, the swatch view renders the image instead of the gradient + emoji.
    var swatchImageName: String? {
        switch self {
        case .paperGreen:  return nil
        case .pink:        return "PinkSwatch"
        case .leafGreen:   return "LeafGreenSwatch"
        case .ink:         return "InkSwatch"
        case .starryNight: return nil
        }
    }

    /// Forces the iOS chrome (status bar, nav bar text, tab bar material) into a
    /// specific color scheme so the theme reads consistently regardless of the
    /// device's system appearance. Without this, navigation-bar titles, system
    /// materials, and SF Symbols pick up the device dark trait and turn white over
    /// our pink/paper backgrounds. Each theme owns the color scheme it was designed
    /// for; only `starryNight` is dark. (When `followSystemDark` is enabled, the
    /// caller passes `nil` to this modifier instead so the device's system flips
    /// can drive the theme; see `ContentView`.)
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .starryNight: return .dark
        case .paperGreen, .pink, .leafGreen, .ink: return .light
        }
    }
}

/// Describes how a theme paints its full-screen background. New cases (e.g. mesh
/// gradient, image-textured paper) can be added without touching consumer views — the
/// `ThemeBackgroundView` switch is the single render site.
enum AppThemeBackground: Hashable {
    case solid(Color)
    case linearGradient(colors: [Color], start: UnitPoint, end: UnitPoint)
    /// Soft blush gradient with low-opacity decorative blobs. The associated colors are
    /// the gradient stops (top → bottom).
    case blushPattern(gradient: [Color])
    /// Asset-image background layered over a soft gradient base. Use for themes whose
    /// pattern is hand-painted (e.g. watercolor petals) rather than procedurally drawn.
    /// `imageOpacity` blends the asset over the gradient so it reads as texture, not
    /// foreground.
    case imagePattern(imageName: String, gradient: [Color], imageOpacity: Double, imageScale: CGFloat)
    /// Procedurally-drawn dark sky: deep navy gradient + soft nebula radial glow + a
    /// fixed scatter of tiny star dots (some blurred for glow). Star positions are
    /// hardcoded so they don't reshuffle on every redraw.
    case starryNight
}

@MainActor
final class AppThemeManager: ObservableObject {
    static let storageKey = "app.theme"
    static let followSystemDarkKey = "app.followSystemDark"

    @AppStorage(AppThemeManager.storageKey) private var storedRawValue: String = AppTheme.paperGreen.rawValue
    @AppStorage(AppThemeManager.followSystemDarkKey) private var storedFollowSystemDark: Bool = false

    /// Theme the user picked from the Settings swatches. When `followSystemDark` is on this is
    /// also the light fallback used while the device is in light mode.
    var current: AppTheme {
        AppTheme(rawValue: storedRawValue) ?? .paperGreen
    }

    var followSystemDark: Bool { storedFollowSystemDark }

    /// Resolves the actually-displayed theme. When `followSystemDark` is on, `.starryNight`
    /// activates only while the device is in dark mode; otherwise the manual selection is used
    /// (downgraded to `.paperGreen` if the manual selection was itself `.starryNight`, so the
    /// app doesn't appear "stuck on dark" after enabling follow-system).
    func effectiveTheme(for systemColorScheme: ColorScheme) -> AppTheme {
        guard storedFollowSystemDark else { return current }
        if systemColorScheme == .dark { return .starryNight }
        return current == .starryNight ? .paperGreen : current
    }

    func select(_ theme: AppTheme) {
        guard theme != current else { return }
        objectWillChange.send()
        storedRawValue = theme.rawValue
    }

    func setFollowSystemDark(_ enabled: Bool) {
        guard enabled != storedFollowSystemDark else { return }
        objectWillChange.send()
        storedFollowSystemDark = enabled
        // If the user's manual pick was the dark theme itself, downgrade it to the default
        // light theme so the light-mode fallback doesn't stay stuck on starryNight.
        if enabled, current == .starryNight {
            storedRawValue = AppTheme.paperGreen.rawValue
        }
    }
}

/// Publishes the device's actual user-interface style as a SwiftUI-friendly
/// `ColorScheme`, *bypassing* any `.preferredColorScheme(...)` override the app
/// applies at the window level. SwiftUI's `\.colorScheme` env reflects the
/// override, so reader follow-system-dark would otherwise be locked to whatever
/// app theme the user picked. Read straight from the active scene's screen
/// (window overrides don't mask the screen's trait collection) and refresh on
/// scene-activation notifications so changes made via the system Settings app
/// update on return-to-foreground.
@MainActor
final class SystemAppearance: ObservableObject {
    @Published private(set) var isDark: Bool

    private var observers: [NSObjectProtocol] = []

    init() {
        isDark = Self.readScreenIsDark()
        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIScene.didActivateNotification
        ]
        for name in names {
            let obs = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(obs)
        }
    }

    deinit {
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
    }

    func refresh() {
        let next = Self.readScreenIsDark()
        if next != isDark { isDark = next }
    }

    private static func readScreenIsDark() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let style = scenes.first?.screen.traitCollection.userInterfaceStyle ?? .unspecified
        return style == .dark
    }
}

/// Publishes the active key window's `safeAreaInsets`. The reader's outer container uses
/// `.ignoresSafeArea()` so that the page background can extend edge-to-edge on every
/// device — but that modifier zeroes the insets that propagate down into the
/// GeometryReader, which means `proxy.safeAreaInsets.leading/.trailing` reads as 0 and
/// the body text would slide under a landscape Dynamic Island, notch, or iPad rounded
/// corner. Reading directly from the window bypasses the SwiftUI consumption and adapts
/// to every iPhone/iPad model automatically (notch, island, regular bezel, all the same).
///
/// Updates on scene-activation, orientation, and frame-change notifications so the values
/// stay correct across portrait/landscape flips and Stage Manager / Split View resizes.
@MainActor
final class WindowSafeAreaInsets: ObservableObject {
    @Published private(set) var insets: UIEdgeInsets

    private var observers: [NSObjectProtocol] = []

    init() {
        insets = Self.readKeyWindowInsets()
        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIScene.didActivateNotification,
            UIDevice.orientationDidChangeNotification,
            UIWindow.didBecomeKeyNotification,
            // Catches Stage Manager / Split View resizes on iPad and the post-rotation
            // settling pass that lands the trailing/leading inset on its final value.
            UIApplication.didChangeStatusBarOrientationNotification
        ]
        for name in names {
            let obs = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(obs)
        }
    }

    deinit {
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
    }

    func refresh() {
        let next = Self.readKeyWindowInsets()
        if next != insets { insets = next }
    }

    private static func readKeyWindowInsets() -> UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? .zero
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppTheme = .paperGreen
}

extension EnvironmentValues {
    /// Active app theme. Inject at the root via `.environment(\.appTheme, manager.current)`;
    /// chrome views read via `@Environment(\.appTheme) private var theme`.
    var appTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}

/// Renders the active theme's full-screen background. Place at the bottom of a
/// `ZStack` (or as a `.background(...)`) in each top-level chrome screen.
///
///     ZStack {
///         ThemeBackgroundView()
///         // … screen content
///     }
///
/// The view reads the active theme from `\.appTheme`, so consumers don't need to
/// thread the theme themselves.
struct ThemeBackgroundView: View {
    @Environment(\.appTheme) private var theme

    // Two-layer cross-dissolve. SwiftUI's `.transition`/`.id` crossfade was
    // unreliable here: every themed background is rooted in a `GeometryReader`
    // (image + starry views), and GeometryReader suppresses transitions — so
    // only some swaps animated. Animating a plain `.opacity` on stacked layers
    // is deterministic for every theme. `settled` is the fully-shown layer;
    // on a change we keep it underneath and fade the new theme in on top.
    @State private var settled: AppTheme?
    @State private var incoming: AppTheme?
    @State private var incomingOpacity: Double = 0

    var body: some View {
        ZStack {
            background(for: settled ?? theme)
            if let incoming {
                background(for: incoming)
                    .opacity(incomingOpacity)
            }
        }
        .ignoresSafeArea()
        .onAppear { if settled == nil { settled = theme } }
        .onChange(of: theme) { oldValue, newValue in
            guard newValue != (settled ?? oldValue) else { return }
            // Pin the old theme as the base, fade the new one in over it.
            settled = oldValue
            incoming = newValue
            incomingOpacity = 0
            withAnimation(.easeInOut(duration: 0.5)) {
                incomingOpacity = 1
            } completion: {
                // Skip if a newer switch superseded this fade mid-flight.
                guard incoming == newValue else { return }
                settled = newValue
                incoming = nil
                incomingOpacity = 0
            }
        }
    }

    @ViewBuilder
    private func background(for theme: AppTheme) -> some View {
        switch theme.backgroundStyle {
        case .solid(let color):
            color

        case .linearGradient(let colors, let start, let end):
            LinearGradient(colors: colors, startPoint: start, endPoint: end)

        case .blushPattern(let gradient):
            BlushPatternBackground(gradient: gradient)

        case .imagePattern(let imageName, let gradient, let imageOpacity, let imageScale):
            ImagePatternBackground(
                imageName: imageName,
                gradient: gradient,
                imageOpacity: imageOpacity,
                imageScale: imageScale
            )

        case .starryNight:
            StarryNightBackground()
        }
    }
}

/// Pink-theme decorative background: a soft blush gradient with three blurred rose
/// blobs at low opacity. Blob positions intentionally avoid the bottom ~25% of the
/// screen so the iOS tab bar's material blur stays clean and readable.
private struct BlushPatternBackground: View {
    let gradient: [Color]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: gradient,
                    startPoint: .top,
                    endPoint: .bottom
                )

                Circle()
                    .fill(Color(red: 0.96, green: 0.78, blue: 0.83).opacity(0.22))
                    .frame(width: proxy.size.width * 0.85)
                    .blur(radius: 70)
                    .offset(x: -proxy.size.width * 0.32, y: -proxy.size.height * 0.28)

                Circle()
                    .fill(Color(red: 0.99, green: 0.84, blue: 0.86).opacity(0.18))
                    .frame(width: proxy.size.width * 0.95)
                    .blur(radius: 80)
                    .offset(x: proxy.size.width * 0.40, y: -proxy.size.height * 0.05)

                Circle()
                    .fill(Color(red: 0.92, green: 0.72, blue: 0.78).opacity(0.10))
                    .frame(width: proxy.size.width * 0.55)
                    .blur(radius: 55)
                    .offset(x: -proxy.size.width * 0.10, y: proxy.size.height * 0.18)

                // Bottom safety fade — keeps the pattern from bleeding into the tab
                // bar's blur where it would muddy the system glyphs.
                LinearGradient(
                    colors: [Color.clear, gradient.last ?? Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.22)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Asset-image background blended over a soft gradient base. The image is drawn via
/// `.scaledToFill()` so it covers any iPhone aspect ratio, then dropped to a low
/// opacity so it reads as texture rather than foreground. A bottom safety fade keeps
/// the pattern from muddying the tab bar's material blur, matching `BlushPatternBackground`.
private struct ImagePatternBackground: View {
    let imageName: String
    let gradient: [Color]
    let imageOpacity: Double
    let imageScale: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: gradient,
                    startPoint: .top,
                    endPoint: .bottom
                )

                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(imageScale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .opacity(imageOpacity)
                    .allowsHitTesting(false)
                    .clipped()

                LinearGradient(
                    colors: [Color.clear, gradient.last ?? Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.22)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Procedurally-drawn dark sky: deep navy gradient + soft purple nebula radial + a
/// fixed scatter of tiny star dots (a few with `.blur` for glow). Star positions are
/// hardcoded so they stay fixed across redraws — no flickering when SwiftUI re-evaluates.
private struct StarryNightBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.16),
                        Color(red: 0.04, green: 0.05, blue: 0.10),
                        Color(red: 0.04, green: 0.05, blue: 0.09)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Off-center nebula glow — single soft purple radial in the upper third.
                // Heavy blur keeps it from looking like a lens flare.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.32, green: 0.22, blue: 0.50).opacity(0.22),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: proxy.size.width * 0.55
                        )
                    )
                    .frame(width: proxy.size.width * 1.2, height: proxy.size.width * 1.2)
                    .blur(radius: 80)
                    .offset(x: -proxy.size.width * 0.05, y: -proxy.size.height * 0.18)
                    .allowsHitTesting(false)

                // Stars. A handful are blurred to read as glow without piling on a
                // separate "glow shape" pass.
                ForEach(StarryNightBackground.stars.indices, id: \.self) { index in
                    let star = StarryNightBackground.stars[index]
                    Circle()
                        .fill(Color.white)
                        .opacity(star.opacity)
                        .frame(width: star.size, height: star.size)
                        .blur(radius: star.glow ? 1.2 : 0)
                        .position(
                            x: star.x * proxy.size.width,
                            y: star.y * proxy.size.height
                        )
                        .allowsHitTesting(false)
                }

                // Bottom safety fade — the tab bar's material blur reads cleaner over a
                // near-solid surface than over a star-speckled one.
                LinearGradient(
                    colors: [Color.clear, Color(red: 0.04, green: 0.05, blue: 0.09)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.22)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
        }
    }

    private struct Star: Hashable {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let opacity: Double
        let glow: Bool
    }

    /// Hand-placed star scatter — distribution is intentionally uneven (small clusters
    /// + sparse regions) so it reads as sky rather than a regular grid. Most stars are
    /// dim; ~10% glow.
    private static let stars: [Star] = [
        Star(x: 0.07, y: 0.06, size: 1.2, opacity: 0.45, glow: false),
        Star(x: 0.18, y: 0.04, size: 2.0, opacity: 0.85, glow: true),
        Star(x: 0.28, y: 0.10, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.39, y: 0.07, size: 1.4, opacity: 0.60, glow: false),
        Star(x: 0.51, y: 0.11, size: 1.2, opacity: 0.50, glow: false),
        Star(x: 0.63, y: 0.05, size: 2.4, opacity: 0.95, glow: true),
        Star(x: 0.74, y: 0.13, size: 1.3, opacity: 0.55, glow: false),
        Star(x: 0.86, y: 0.08, size: 1.1, opacity: 0.45, glow: false),
        Star(x: 0.94, y: 0.16, size: 1.0, opacity: 0.40, glow: false),

        Star(x: 0.04, y: 0.20, size: 1.1, opacity: 0.40, glow: false),
        Star(x: 0.13, y: 0.24, size: 1.6, opacity: 0.70, glow: false),
        Star(x: 0.24, y: 0.19, size: 1.0, opacity: 0.38, glow: false),
        Star(x: 0.36, y: 0.27, size: 1.4, opacity: 0.58, glow: false),
        Star(x: 0.47, y: 0.22, size: 2.2, opacity: 0.92, glow: true),
        Star(x: 0.59, y: 0.28, size: 1.3, opacity: 0.50, glow: false),
        Star(x: 0.71, y: 0.20, size: 1.5, opacity: 0.65, glow: false),
        Star(x: 0.82, y: 0.26, size: 1.1, opacity: 0.42, glow: false),
        Star(x: 0.93, y: 0.30, size: 1.0, opacity: 0.36, glow: false),

        Star(x: 0.08, y: 0.36, size: 1.4, opacity: 0.58, glow: false),
        Star(x: 0.20, y: 0.40, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.33, y: 0.34, size: 1.7, opacity: 0.75, glow: false),
        Star(x: 0.45, y: 0.42, size: 2.5, opacity: 1.00, glow: true),
        Star(x: 0.57, y: 0.37, size: 1.2, opacity: 0.48, glow: false),
        Star(x: 0.69, y: 0.43, size: 1.4, opacity: 0.58, glow: false),
        Star(x: 0.81, y: 0.38, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.91, y: 0.45, size: 1.1, opacity: 0.42, glow: false),

        Star(x: 0.05, y: 0.50, size: 1.0, opacity: 0.38, glow: false),
        Star(x: 0.16, y: 0.54, size: 1.3, opacity: 0.52, glow: false),
        Star(x: 0.29, y: 0.48, size: 1.9, opacity: 0.82, glow: true),
        Star(x: 0.42, y: 0.56, size: 1.1, opacity: 0.42, glow: false),
        Star(x: 0.54, y: 0.51, size: 1.4, opacity: 0.60, glow: false),
        Star(x: 0.66, y: 0.57, size: 1.0, opacity: 0.38, glow: false),
        Star(x: 0.78, y: 0.53, size: 1.6, opacity: 0.68, glow: false),
        Star(x: 0.90, y: 0.59, size: 1.1, opacity: 0.42, glow: false),

        Star(x: 0.10, y: 0.66, size: 1.5, opacity: 0.62, glow: false),
        Star(x: 0.23, y: 0.70, size: 1.0, opacity: 0.36, glow: false),
        Star(x: 0.36, y: 0.64, size: 1.2, opacity: 0.48, glow: false),
        Star(x: 0.49, y: 0.72, size: 2.1, opacity: 0.90, glow: true),
        Star(x: 0.62, y: 0.67, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.75, y: 0.73, size: 1.3, opacity: 0.52, glow: false),
        Star(x: 0.88, y: 0.68, size: 1.0, opacity: 0.36, glow: false),

        Star(x: 0.14, y: 0.82, size: 1.1, opacity: 0.40, glow: false),
        Star(x: 0.30, y: 0.86, size: 1.0, opacity: 0.34, glow: false),
        Star(x: 0.46, y: 0.80, size: 1.5, opacity: 0.58, glow: false),
        Star(x: 0.61, y: 0.84, size: 1.0, opacity: 0.36, glow: false),
        Star(x: 0.76, y: 0.81, size: 1.2, opacity: 0.45, glow: false),

        // Filler dim stars — broken into smaller dots so the sky reads dense without
        // clumping. Mostly opacity < 0.5 so the bright stars above keep their hierarchy.
        Star(x: 0.02, y: 0.12, size: 0.9, opacity: 0.32, glow: false),
        Star(x: 0.11, y: 0.14, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.32, y: 0.04, size: 0.8, opacity: 0.30, glow: false),
        Star(x: 0.45, y: 0.16, size: 1.0, opacity: 0.45, glow: false),
        Star(x: 0.57, y: 0.02, size: 0.9, opacity: 0.36, glow: false),
        Star(x: 0.69, y: 0.09, size: 1.0, opacity: 0.42, glow: false),
        Star(x: 0.80, y: 0.18, size: 1.4, opacity: 0.62, glow: false),
        Star(x: 0.91, y: 0.04, size: 0.9, opacity: 0.38, glow: false),

        Star(x: 0.08, y: 0.32, size: 0.9, opacity: 0.34, glow: false),
        Star(x: 0.20, y: 0.32, size: 1.1, opacity: 0.45, glow: false),
        Star(x: 0.30, y: 0.24, size: 0.8, opacity: 0.30, glow: false),
        Star(x: 0.41, y: 0.31, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.53, y: 0.18, size: 0.9, opacity: 0.34, glow: false),
        Star(x: 0.65, y: 0.31, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.76, y: 0.27, size: 1.2, opacity: 0.50, glow: false),
        Star(x: 0.88, y: 0.21, size: 0.9, opacity: 0.34, glow: false),

        Star(x: 0.02, y: 0.42, size: 0.9, opacity: 0.32, glow: false),
        Star(x: 0.13, y: 0.41, size: 1.0, opacity: 0.42, glow: false),
        Star(x: 0.26, y: 0.39, size: 0.8, opacity: 0.30, glow: false),
        Star(x: 0.39, y: 0.46, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.51, y: 0.34, size: 1.2, opacity: 0.55, glow: false),
        Star(x: 0.62, y: 0.41, size: 0.9, opacity: 0.36, glow: false),
        Star(x: 0.74, y: 0.45, size: 1.0, opacity: 0.42, glow: false),
        Star(x: 0.86, y: 0.36, size: 0.9, opacity: 0.34, glow: false),
        Star(x: 0.97, y: 0.42, size: 0.8, opacity: 0.30, glow: false),

        Star(x: 0.10, y: 0.61, size: 0.9, opacity: 0.34, glow: false),
        Star(x: 0.21, y: 0.50, size: 1.0, opacity: 0.42, glow: false),
        Star(x: 0.34, y: 0.59, size: 0.8, opacity: 0.32, glow: false),
        Star(x: 0.46, y: 0.50, size: 1.1, opacity: 0.46, glow: false),
        Star(x: 0.58, y: 0.62, size: 0.9, opacity: 0.36, glow: false),
        Star(x: 0.71, y: 0.50, size: 1.2, opacity: 0.52, glow: false),
        Star(x: 0.83, y: 0.62, size: 0.9, opacity: 0.36, glow: false),
        Star(x: 0.95, y: 0.52, size: 1.0, opacity: 0.40, glow: false),

        Star(x: 0.04, y: 0.71, size: 0.9, opacity: 0.34, glow: false),
        Star(x: 0.17, y: 0.65, size: 1.0, opacity: 0.42, glow: false),
        Star(x: 0.29, y: 0.74, size: 0.8, opacity: 0.30, glow: false),
        Star(x: 0.42, y: 0.66, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.55, y: 0.74, size: 1.0, opacity: 0.42, glow: false),
        Star(x: 0.68, y: 0.65, size: 0.9, opacity: 0.36, glow: false),
        Star(x: 0.81, y: 0.71, size: 1.2, opacity: 0.50, glow: false),
        Star(x: 0.95, y: 0.74, size: 0.9, opacity: 0.36, glow: false),

        Star(x: 0.06, y: 0.80, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.22, y: 0.83, size: 0.9, opacity: 0.34, glow: false),
        Star(x: 0.39, y: 0.86, size: 0.8, opacity: 0.30, glow: false),
        Star(x: 0.55, y: 0.88, size: 0.9, opacity: 0.32, glow: false),
        Star(x: 0.69, y: 0.86, size: 1.0, opacity: 0.40, glow: false),
        Star(x: 0.83, y: 0.85, size: 0.9, opacity: 0.34, glow: false)
    ]
}

/// Mini constellation drawn on the Settings swatch. Five small white dots — same
/// procedural look as the full-screen background, just at swatch scale (no blur, since
/// any blur reads as a smudge at 44pt).
private struct SwatchStarsOverlay: View {
    private struct MiniStar {
        let x: CGFloat       // 0...1 of swatch width
        let y: CGFloat       // 0...1 of swatch height
        let size: CGFloat    // pt
        let opacity: Double
    }

    private let stars: [MiniStar] = [
        MiniStar(x: 0.22, y: 0.20, size: 1.8, opacity: 1.00),
        MiniStar(x: 0.55, y: 0.16, size: 1.2, opacity: 0.70),
        MiniStar(x: 0.78, y: 0.40, size: 1.4, opacity: 0.85),
        MiniStar(x: 0.32, y: 0.55, size: 1.0, opacity: 0.55),
        MiniStar(x: 0.66, y: 0.72, size: 1.2, opacity: 0.70)
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(stars.indices, id: \.self) { index in
                let star = stars[index]
                Circle()
                    .fill(Color.white)
                    .opacity(star.opacity)
                    .frame(width: star.size, height: star.size)
                    .position(
                        x: star.x * proxy.size.width,
                        y: star.y * proxy.size.height
                    )
            }
        }
    }
}
