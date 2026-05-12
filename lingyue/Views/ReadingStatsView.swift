import SwiftUI

// MARK: - Stats visual system
//
// The Stats tab uses a fixed "paper-style dashboard" palette that stays the same
// regardless of which AppTheme the user picks — so cards always read as warm ivory
// instead of being tinted by the surrounding chrome. The selected theme still
// shows through as: (a) the page background image/pattern behind a soft neutral
// haze, and (b) `theme.accent` used sparingly on segmented pickers, the hero
// progress bar, calendar selection ring, and the trend-chart bars.
//
// Semantic accents below are intentionally muted (no neon, no rainbow) — they
// exist to give data categories visual identity (gold = streak, sage = focus,
// inkBlue = pace, clay = words/books, rose = highlight) without competing with
// the literary tone of the rest of the app.

private struct StatsPalette {
    let surface: Color           // primary card fill (warm ivory)
    let surfaceMuted: Color      // recessed pill / chip fill
    let surfaceElevated: Color   // hero card fill (slightly brighter than `surface`)
    let border: Color            // hairline border around cards
    let shadow: Color            // soft warm card shadow
    let divider: Color           // metric-strip dividers
    let primaryText: Color
    let secondaryText: Color

    let gold: Color              // streak / achievement
    let sage: Color              // focus / daily summary
    let inkBlue: Color           // reading pace
    let clay: Color              // words / books
    let rose: Color              // accent highlight

    // 5-step heatmap ladder: index 0 = no reading, index 4 = strongest.
    // Picked per-theme so the heatmap reads as "reading" rather than a generic
    // green health/fitness grid. The calendar uses `readingAccent` (a softer mid
    // tone from the same family) so it ties back to the heatmap without screaming.
    let heatLevels: [Color]
    let readingAccent: Color

    // "Reading time" accent. Always warm — never the cold ink-grey that
    // `theme.accent` resolves to for the ink theme. The hero number stripe, daily
    // progress bar, hero chart-icon chip, metric `总时长`, the period-summary
    // duration text, and the trend-chart bars all pull from this so reading time
    // reads as a single semantic color across the page.
    let readingTime: Color
    let chartGradient: [Color]   // [top, bottom] for trend bar fills
    let chartGridLine: Color     // subtle hairline for chart baseline + grid
    let progressTrack: Color     // theme-tinted rail behind the goal progress bar
    let heroGradient: [Color]    // top→bottom sweep painted inside the hero card
    let badgeBackground: Color   // warm beige for the "已移出书架" tag
    let badgeForeground: Color
    // Soft theme-tinted color used as a low-opacity shadow / aura under accents
    // (progress bar fill, streak badge, selected chart bar, selected calendar day).
    // Always the same hue family as `readingTime`; never gaming-RGB neon.
    let glow: Color

    // Lower-section card surface — a translucent vertical gradient that lets the
    // page background bleed through subtly so the heatmap + ranking don't feel
    // like flat white components stuck onto the page.
    let lowerCardGradient: [Color]

    // Segmented control (used by the ranking range picker). Custom-rendered so
    // it matches the literary tone instead of the stock iOS pill style.
    let segmentedTrack: Color
    let segmentedActive: Color

    /// Rotating accent for the top-books leaderboard rank circles. Gold for #1,
    /// then dusty blue / sage / clay / rose so each rank reads as its own role
    /// without rainbow chaos.
    var rankAccents: [Color] { [gold, inkBlue, sage, clay, rose] }

    static func light(for theme: AppTheme) -> StatsPalette {
        let ladder = lightHeatLadder(for: theme)
        let reading = lightReadingTime(for: theme)
        let chart = lightChartGradient(for: theme)
        let achievement = lightAchievement(for: theme)
        let surfaces = lightSurfaces(for: theme)
        return StatsPalette(
            // Surfaces are theme-aware so Sakura escapes the warm-cream cast.
            // Sakura → airy blush white (#FDF7F8); Ink / Forest stay on warm paper.
            surface:          surfaces.base,
            surfaceMuted:     surfaces.muted,
            surfaceElevated:  surfaces.elevated,
            border:           Color.black.opacity(0.06),
            shadow:           Color.black.opacity(0.05),
            divider:          Color.black.opacity(0.07),
            // Strong near-black main text + a darker, less misty secondary so
            // labels stay legible against the warm paper.
            primaryText:      Color(red: 0.105, green: 0.098, blue: 0.086),
            secondaryText:    Color(red: 0.355, green: 0.325, blue: 0.275),
            // `gold` is the streak/achievement/rank-1 accent — theme-aware so Sakura
            // never resolves to a mustard yellow on a pink page. Kept the field name
            // for compatibility with downstream callers.
            gold:             achievement,
            sage:             Color(red: 0.561, green: 0.655, blue: 0.557),
            inkBlue:          Color(red: 0.431, green: 0.502, blue: 0.596),
            clay:             Color(red: 0.78, green: 0.604, blue: 0.482),
            rose:             Color(red: 0.78, green: 0.522, blue: 0.573),
            heatLevels:       ladder,
            // Calendar fill = mid-ladder (level 2) — softer than the dark cells
            // but still clearly part of the same color family.
            readingAccent:    ladder[2],
            readingTime:      reading,
            chartGradient:    chart,
            chartGridLine:    Color.black.opacity(0.09),
            progressTrack:    lightProgressTrack(for: theme),
            heroGradient:     lightHeroGradient(for: theme),
            badgeBackground:  Color(red: 0.937, green: 0.871, blue: 0.804), // warm beige
            badgeForeground:  Color(red: 0.478, green: 0.349, blue: 0.275), // warm clay text
            glow:             lightGlow(for: theme),
            lowerCardGradient: lightLowerCardGradient(for: theme),
            segmentedTrack:    lightSegmentedTrack(for: theme),
            segmentedActive:   Color.white.opacity(0.92)
        )
    }

    static func dark(for theme: AppTheme) -> StatsPalette {
        let ladder = darkHeatLadder(for: theme)
        // Exact deep-midnight palette: muted #161B2C, base #1A2033, elevated #1C2340.
        // Indigo over neutral grey so the navy stays the dominant note; accents
        // separate cleanly without brightening the overall UI.
        return StatsPalette(
            surface:          Color(red: 0.102, green: 0.125, blue: 0.200), // #1A2033
            surfaceMuted:     Color(red: 0.086, green: 0.106, blue: 0.173), // #161B2C
            surfaceElevated:  Color(red: 0.110, green: 0.137, blue: 0.251), // #1C2340
            border:           Color.white.opacity(0.07),
            shadow:           Color.black.opacity(0.40),
            divider:          Color.white.opacity(0.09),
            primaryText:      Color(red: 0.96, green: 0.94, blue: 0.88),
            secondaryText:    Color(red: 0.78, green: 0.74, blue: 0.65),
            gold:             Color(red: 0.878, green: 0.769, blue: 0.561), // #E0C48F
            sage:             Color(red: 0.66, green: 0.79, blue: 0.64),
            inkBlue:          Color(red: 0.60, green: 0.68, blue: 0.80),
            clay:             Color(red: 0.86, green: 0.69, blue: 0.55),
            rose:             Color(red: 0.86, green: 0.60, blue: 0.65),
            heatLevels:       ladder,
            readingAccent:    ladder[2],
            readingTime:      Color(red: 0.878, green: 0.769, blue: 0.561), // #E0C48F
            chartGradient: [
                Color(red: 0.878, green: 0.769, blue: 0.561), // #E0C48F
                Color(red: 0.784, green: 0.643, blue: 0.416)  // #C8A46A
            ],
            chartGridLine:    Color.white.opacity(0.09),
            progressTrack:    Color(red: 0.878, green: 0.769, blue: 0.561).opacity(0.18),
            heroGradient: [
                Color(red: 0.110, green: 0.137, blue: 0.251), // #1C2340
                Color(red: 0.094, green: 0.118, blue: 0.196)  // deeper indigo for the falloff
            ],
            badgeBackground:  Color(red: 0.42, green: 0.34, blue: 0.27),
            badgeForeground:  Color(red: 0.92, green: 0.85, blue: 0.74),
            glow:             Color(red: 0.878, green: 0.769, blue: 0.561), // celestial gold halo
            // Lower-section translucent gradient — indigo lift at the top, deeper
            // navy at the bottom; mirrors the heroGradient mood so the lower half
            // feels of-a-piece with the hero.
            lowerCardGradient: [
                Color(red: 0.122, green: 0.149, blue: 0.224),
                Color(red: 0.094, green: 0.118, blue: 0.196)
            ],
            segmentedTrack:    Color(red: 0.086, green: 0.106, blue: 0.173).opacity(0.78),
            segmentedActive:   Color(red: 0.165, green: 0.196, blue: 0.298)
        )
    }

    /// Theme primary accent — same color the streak badge, progress bar, chart icon
    /// circle, and reading-time metric pull from. Picked per theme so Sakura reads as
    /// luminous rose (not mustard gold), Forest as breathable green, Ink as warm sepia.
    private static func lightReadingTime(for theme: AppTheme) -> Color {
        switch theme {
        case .pink:                            return Color(red: 0.788, green: 0.486, blue: 0.588) // #C97C96
        case .ink:                             return Color(red: 0.655, green: 0.525, blue: 0.369) // #A7865E warm sepia
        case .paperGreen, .leafGreen:          return Color(red: 0.435, green: 0.561, blue: 0.447) // #6F8F72
        case .starryNight:                     return Color(red: 0.878, green: 0.769, blue: 0.561) // #E0C48F
        }
    }

    /// Streak / achievement / rank-1 accent. Decoupled from `readingTime` so each theme
    /// can paint achievement-style elements in a related but distinct accent. Sakura
    /// gets a softer rose (#D9A7B8 highlight), keeping the streak feel romantic rather
    /// than yellow-gold; Ink keeps warm paper-gold; Forest uses deep moss; Starry
    /// keeps champagne for the celestial mood.
    private static func lightAchievement(for theme: AppTheme) -> Color {
        switch theme {
        case .pink:                            return Color(red: 0.788, green: 0.486, blue: 0.588) // #C97C96 primary rose
        case .ink:                             return Color(red: 0.776, green: 0.690, blue: 0.541) // #C6B08A muted paper gold
        case .paperGreen, .leafGreen:          return Color(red: 0.333, green: 0.455, blue: 0.353) // #55745A deep moss
        case .starryNight:                     return Color(red: 0.878, green: 0.769, blue: 0.561) // #E0C48F
        }
    }

    /// Bar-chart top→bottom gradient — top is the soft accent, bottom is the deep
    /// accent, so the bars carry an internal light-to-shadow falloff that mirrors
    /// the heatmap palette without being a flat duplicate.
    private static func lightChartGradient(for theme: AppTheme) -> [Color] {
        switch theme {
        case .pink:
            return [
                Color(red: 0.851, green: 0.655, blue: 0.722), // #D9A7B8 soft accent
                Color(red: 0.659, green: 0.373, blue: 0.482)  // #A85F7B deep rose
            ]
        case .ink:
            return [
                Color(red: 0.776, green: 0.690, blue: 0.541), // #C6B08A
                Color(red: 0.353, green: 0.318, blue: 0.282)  // #5A5148 soft ink
            ]
        case .paperGreen, .leafGreen:
            return [
                Color(red: 0.553, green: 0.667, blue: 0.545), // #8DAA8B highlight
                Color(red: 0.333, green: 0.455, blue: 0.353)  // #55745A deep
            ]
        case .starryNight:
            return [
                Color(red: 0.878, green: 0.769, blue: 0.561), // #E0C48F
                Color(red: 0.784, green: 0.643, blue: 0.416)  // #C8A46A
            ]
        }
    }

    /// Pale, theme-tinted track for the daily-goal progress bar. Sakura gets the
    /// faintest rose veil, Ink gets warm paper, Forest gets pale moss.
    private static func lightProgressTrack(for theme: AppTheme) -> Color {
        switch theme {
        case .pink:                            return Color(red: 0.953, green: 0.906, blue: 0.922) // #F3E7EB
        case .ink:                             return Color(red: 0.949, green: 0.933, blue: 0.906) // #F2EEE7
        case .paperGreen, .leafGreen:          return Color(red: 0.929, green: 0.953, blue: 0.925) // #EDF3EC
        case .starryNight:                     return Color(red: 0.913, green: 0.875, blue: 0.812) // warm beige fallback
        }
    }

    /// Soft theme-aware ambient glow (used as a Color value, applied at low opacity
    /// as a shadow). Sakura → cherry-blossom rose, Ink → sepia, Forest → moss, Starry
    /// → champagne. Same color as `readingTime` by design but exposed separately so
    /// the glow opacity can be tuned independently of icon/text contrast.
    private static func lightGlow(for theme: AppTheme) -> Color {
        lightReadingTime(for: theme)
    }

    /// Per-theme card surface trio. Sakura needs to escape the warm-cream cast that
    /// previously pulled the whole page toward yellow; Ink and Forest still want the
    /// editorial paper feel so they stay on warm ivory.
    private static func lightSurfaces(for theme: AppTheme) -> (base: Color, muted: Color, elevated: Color) {
        switch theme {
        case .pink:
            // Sakura: airy blush white — a luminous pink haze, not warm cream.
            return (
                base:     Color(red: 0.992, green: 0.969, blue: 0.973), // #FDF7F8
                muted:    Color(red: 0.980, green: 0.957, blue: 0.965), // #FAF4F6
                elevated: Color(red: 1.000, green: 0.976, blue: 0.980)  // #FFF9FA
            )
        default:
            return (
                base:     Color(red: 1.000, green: 0.992, blue: 0.973), // warm ivory
                muted:    Color(red: 0.961, green: 0.949, blue: 0.918),
                elevated: Color(red: 1.000, green: 0.996, blue: 0.984)
            )
        }
    }

    /// Per-theme translucent gradient for the heatmap + ranking cards. Sakura uses
    /// the exact rgba(255,252,253,0.92)→rgba(252,246,248,0.96) blush veil from the
    /// brief; other themes get analog veils in their own hue so the lower half
    /// reads as continuous with each theme's atmosphere instead of flat white.
    private static func lightLowerCardGradient(for theme: AppTheme) -> [Color] {
        switch theme {
        case .pink:
            return [
                Color(red: 1.000, green: 0.988, blue: 0.992).opacity(0.92), // #FFFCFD
                Color(red: 0.988, green: 0.965, blue: 0.973).opacity(0.96)  // #FCF6F8
            ]
        case .ink:
            return [
                Color(red: 1.000, green: 0.996, blue: 0.984).opacity(0.94),
                Color(red: 0.988, green: 0.969, blue: 0.929).opacity(0.96)
            ]
        case .paperGreen, .leafGreen:
            return [
                Color(red: 0.996, green: 1.000, blue: 0.988).opacity(0.94),
                Color(red: 0.965, green: 0.984, blue: 0.957).opacity(0.96)
            ]
        case .starryNight:
            return [
                Color(red: 0.122, green: 0.149, blue: 0.224),
                Color(red: 0.094, green: 0.118, blue: 0.196)
            ]
        }
    }

    /// Outer track for the custom segmented control. Theme-tinted soft pink-grey
    /// for Sakura (exact rgba(232,222,227,0.72) from spec); ivory/sage/moss for
    /// the literary light themes.
    private static func lightSegmentedTrack(for theme: AppTheme) -> Color {
        switch theme {
        case .pink:                    return Color(red: 0.910, green: 0.871, blue: 0.890).opacity(0.72) // #E8DEE3
        case .ink:                     return Color(red: 0.871, green: 0.827, blue: 0.757).opacity(0.55)
        case .paperGreen, .leafGreen:  return Color(red: 0.839, green: 0.890, blue: 0.827).opacity(0.55)
        case .starryNight:             return Color(red: 0.086, green: 0.106, blue: 0.173).opacity(0.78)
        }
    }

    /// Top→bottom sweep painted inside the hero card. Sakura gets a faint blush
    /// veil so the hero reads as a luminous petal sweep instead of warm cream.
    private static func lightHeroGradient(for theme: AppTheme) -> [Color] {
        switch theme {
        case .pink:
            return [
                Color(red: 1.000, green: 0.980, blue: 0.984), // #FFFAFB
                Color(red: 0.984, green: 0.933, blue: 0.945)  // #FBEEF1 soft blush sweep
            ]
        default:
            return [
                Color(red: 1.000, green: 0.996, blue: 0.984),
                Color(red: 0.984, green: 0.953, blue: 0.886)
            ]
        }
    }

    /// Per-theme 5-step heatmap ladders. Tuned for "luminous cherry blossom" (Sakura),
    /// "editorial sepia on paper" (Ink), and "sunlight-through-leaves moss" (Forest);
    /// starryNight uses the dark champagne ramp via `darkHeatLadder`.
    private static func lightHeatLadder(for theme: AppTheme) -> [Color] {
        switch theme {
        case .pink:
            // Softer empty floor + richer active steps so the heatmap feels
            // intentional rather than pale background noise.
            return [
                Color(red: 0.973, green: 0.945, blue: 0.957), // #F8F1F4 empty floor
                Color(red: 0.937, green: 0.839, blue: 0.878), // #EFD6E0 lightest active
                Color(red: 0.875, green: 0.655, blue: 0.745), // #DFA7BE
                Color(red: 0.808, green: 0.525, blue: 0.651), // #CE86A6
                Color(red: 0.741, green: 0.435, blue: 0.573)  // #BD6F92 strongest active
            ]
        case .ink:
            // Editorial sepia on paper: #F2EEE7 → #DED3C1 → #C6B08A → #A7865E → #5A5148.
            return [
                Color(red: 0.949, green: 0.933, blue: 0.906), // #F2EEE7
                Color(red: 0.871, green: 0.827, blue: 0.757), // #DED3C1
                Color(red: 0.776, green: 0.690, blue: 0.541), // #C6B08A
                Color(red: 0.655, green: 0.525, blue: 0.369), // #A7865E
                Color(red: 0.353, green: 0.318, blue: 0.282)  // #5A5148
            ]
        case .paperGreen, .leafGreen, .starryNight:
            // Breathable organic moss: #EDF3EC → #D6E3D3 → #B7C7B2 → #8DAA8B → #55745A.
            return [
                Color(red: 0.929, green: 0.953, blue: 0.925), // #EDF3EC
                Color(red: 0.839, green: 0.890, blue: 0.827), // #D6E3D3
                Color(red: 0.718, green: 0.780, blue: 0.698), // #B7C7B2
                Color(red: 0.553, green: 0.667, blue: 0.545), // #8DAA8B
                Color(red: 0.333, green: 0.455, blue: 0.353)  // #55745A
            ]
        }
    }

    /// Dark mode currently only fires for `.starryNight` (champagne gold accent),
    /// so the dark heatmap ramps from a deep indigo recess up through a solid
    /// celestial gold so the brightest reading weeks read as luminous against the
    /// navy. Solid colors (no opacity tints) keep the top cells from being washed
    /// out by the card behind them.
    private static func darkHeatLadder(for theme: AppTheme) -> [Color] {
        return [
            Color(red: 0.078, green: 0.094, blue: 0.157), // #141828 deeper than surface so empty cells read as recesses
            Color(red: 0.314, green: 0.275, blue: 0.196), // #50463A muted bronze
            Color(red: 0.502, green: 0.420, blue: 0.275), // #806B46 toasted gold
            Color(red: 0.706, green: 0.588, blue: 0.392), // #B49664 ripe gold
            Color(red: 0.878, green: 0.769, blue: 0.561)  // #E0C48F solid primary gold
        ]
    }
}

private struct StatsPaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue: StatsPalette = .light(for: .paperGreen)
}

extension EnvironmentValues {
    fileprivate var statsPalette: StatsPalette {
        get { self[StatsPaletteEnvironmentKey.self] }
        set { self[StatsPaletteEnvironmentKey.self] = newValue }
    }
}

/// Very light warm wash over `ThemeBackgroundView` — just enough to keep card text
/// legible against whatever artwork the theme draws, without veiling the whole page.
/// Previous versions used a 60-80% white overlay which read as frosted-glass fog;
/// this one stays barely-there so the theme art still feels present between cards.
private struct StatsBackgroundDim: View {
    let palette: StatsPalette
    let isDark: Bool

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    // Dark mode: barely-there indigo wash instead of a grey fog so
                    // the navy art reads through cleanly while still giving the
                    // page a hair of vertical falloff for depth.
                    colors: isDark
                        ? [palette.surfaceMuted.opacity(0.10), palette.surfaceMuted.opacity(0.20)]
                        : [palette.surface.opacity(0.18), palette.surface.opacity(0.26)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// Unified Stats card chrome: warm ivory fill, hairline border, soft warm shadow.
/// Use everywhere a card sits on the Stats page so the visual rhythm is consistent.
private struct StatsCardModifier: ViewModifier {
    @Environment(\.statsPalette) private var palette
    var elevated: Bool = false
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(elevated ? palette.surfaceElevated : palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(palette.border, lineWidth: 0.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: palette.shadow, radius: 12, x: 0, y: 6)
    }
}

extension View {
    fileprivate func statsCard(elevated: Bool = false, cornerRadius: CGFloat = 14) -> some View {
        modifier(StatsCardModifier(elevated: elevated, cornerRadius: cornerRadius))
    }

    /// Used by the lower-half cards (heatmap, ranking) so they read as polished
    /// translucent panels instead of flat white components.
    fileprivate func statsLowerCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(StatsLowerCardModifier(cornerRadius: cornerRadius))
    }
}

/// Lower-half card chrome: subtle vertical translucent gradient + hairline border
/// + a slightly softer shadow than the standard `.statsCard()`. The translucency
/// lets the theme background bleed through just enough that the heatmap and
/// ranking cards feel atmospheric, not like opaque rectangles glued onto the page.
private struct StatsLowerCardModifier: ViewModifier {
    @Environment(\.statsPalette) private var palette
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: palette.lowerCardGradient,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(palette.border, lineWidth: 0.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: palette.shadow, radius: 14, x: 0, y: 7)
    }
}

struct ReadingStatsView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedRange: StatsRange = .day
    @State private var selectedTrendPointID: String?
    @State private var selectedHeatmapDay: Date?
    @State private var selectedTopBooksRange: TopBooksRange = .week
    @State private var displayedCalendarMonth: Date = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
    }()
    @AppStorage("stats.dailyGoalMinutes") private var dailyGoalMinutes: Int = 0
    @State private var dayTick: Date = Date()
    @Environment(\.scenePhase) private var scenePhase

    private let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }()

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var mergedBooks: [ReadingStatsBook] {
        var books = libraryStore.readingStats.books
        let knownIDs = Set(books.map(\.id))
        for novel in libraryStore.allNovels where !knownIDs.contains(novel.id) {
            let now = novel.lastOpenedAt ?? Date()
            books.append(
                ReadingStatsBook(
                    id: novel.id,
                    title: novel.title,
                    author: novel.author,
                    coverPalette: novel.coverPalette,
                    coverImageURLString: novel.coverImageURLString,
                    sourceURLString: novel.sourceURLString,
                    firstReadAt: now,
                    lastReadAt: now,
                    deletedAt: nil,
                    currentProgress: novel.progress,
                    totalDurationSeconds: TimeInterval(max(novel.readMinutes, 0) * 60),
                    pageTurns: 0,
                    characterCount: 0
                )
            )
        }
        return books
    }

    private var booksByID: [UUID: ReadingStatsBook] {
        Dictionary(uniqueKeysWithValues: mergedBooks.map { ($0.id, $0) })
    }

    private var totalDuration: TimeInterval {
        libraryStore.readingStats.totalDurationSeconds
    }

    private var totalPages: Int {
        libraryStore.readingStats.totalPageTurns
    }

    private var totalCharacters: Int {
        libraryStore.readingStats.totalCharacterCount
    }

    private var readBookCount: Int {
        mergedBooks.filter { $0.pageTurns > 0 }.count
    }

    private var finishedBookCount: Int {
        mergedBooks.filter { $0.currentProgress >= 0.999 }.count
    }

    private var periodEvents: [ReadingStatsEvent] {
        let interval = selectedRange.interval(containing: Date(), calendar: calendar)
        return libraryStore.readingStats.events.filter { interval.contains($0.timestamp) }
    }

    private var hasAnyReadingData: Bool {
        !libraryStore.readingStats.events.isEmpty
    }

    private var currentMonthStart: Date {
        calendar.dateInterval(of: .month, for: Date())?.start ?? calendar.startOfDay(for: Date())
    }

    private var availableCalendarMonths: [Date] {
        let eventEarliest: Date? = libraryStore.readingStats.events.map(\.timestamp).min().flatMap {
            calendar.dateInterval(of: .month, for: $0)?.start
        }
        let defaultStart = calendar.date(byAdding: .month, value: -23, to: currentMonthStart) ?? currentMonthStart
        let candidates: [Date] = [defaultStart, eventEarliest ?? defaultStart, displayedCalendarMonth]
        var cursor = candidates.min() ?? currentMonthStart
        var months: [Date] = []
        while cursor <= currentMonthStart {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
            if months.count > 600 { break }
        }
        return months
    }

    private var bodySpacing: CGFloat {
        horizontalSizeClass == .compact ? 16 : 20
    }

    private var isDarkStats: Bool {
        theme.preferredColorScheme == .dark
    }

    private var palette: StatsPalette {
        isDarkStats ? .dark(for: theme) : .light(for: theme)
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()
            StatsBackgroundDim(palette: palette, isDark: isDarkStats)

            ScrollView {
                VStack(alignment: .leading, spacing: bodySpacing) {
                    heroCard
                    globalMetrics
                    rangePicker
                    periodSummary
                    trendCard
                    streakCalendarCard
                    heatmapCard
                    topBooksCard
                }
                .padding(.horizontal, horizontalSizeClass == .compact ? 14 : 22)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        }
        .environment(\.statsPalette, palette)
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ReadingHistoryView()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel("浏览记录")
            }
        }
        .sensoryFeedback(.selection, trigger: selectedTrendPointID)
        .sensoryFeedback(.selection, trigger: selectedHeatmapDay)
        .onChange(of: selectedRange) { _, _ in
            selectedTrendPointID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { dayTick = Date() }
        }
        .task(id: dayTick) {
            await waitForNextDay()
        }
    }

    private func waitForNextDay() async {
        var components = DateComponents()
        components.hour = 0
        components.minute = 0
        components.second = 1
        let now = Date()
        let next = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(86_400)
        let interval = max(next.timeIntervalSince(now), 1)
        do {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            dayTick = Date()
        } catch {
            // task cancelled
        }
    }

    private var heroCard: some View {
        let streak = currentStreak(days: dailySummaries(days: 120))
        let minutes = max(Int(totalDuration / 60), 0)
        let todaySeconds = libraryStore.readingStats.events
            .filter { calendar.isDateInToday($0.timestamp) }
            .reduce(0) { $0 + $1.durationSeconds }
        let todayMinutes = max(Int(todaySeconds / 60), 0)
        let hasGoal = dailyGoalMinutes > 0
        let dailyProgress = hasGoal ? min(Double(todayMinutes) / Double(dailyGoalMinutes), 1) : 0
        let goalReached = hasGoal && todayMinutes >= dailyGoalMinutes

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("阅读投入")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(palette.secondaryText.opacity(0.85))
                    Text(formatDuration(totalDuration))
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                    HStack(spacing: 8) {
                        if streak > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("连读 \(streak) 天")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(palette.gold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                palette.gold.opacity(0.28),
                                                palette.gold.opacity(0.14)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            )
                            .overlay(Capsule().stroke(palette.gold.opacity(0.42), lineWidth: 0.7))
                            // Layered glow: a soft theme-tinted aura + a tighter inner
                            // shadow for depth. Stays atmospheric, never harsh.
                            .shadow(color: palette.glow.opacity(0.30), radius: 8, x: 0, y: 2)
                            .shadow(color: palette.glow.opacity(0.18), radius: 2, x: 0, y: 1)
                        }
                        Text(heroSubtitle(minutes: minutes, streak: streak))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.secondaryText.opacity(0.92))
                            .lineLimit(2)
                    }
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    palette.readingTime.opacity(0.32),
                                    palette.readingTime.opacity(0.06)
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: 32
                            )
                        )
                    Circle()
                        .stroke(palette.readingTime.opacity(0.18), lineWidth: 0.6)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(palette.readingTime)
                }
                .frame(width: 58, height: 58)
            }

            if hasGoal {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Menu {
                            dailyGoalMenuItems
                        } label: {
                            HStack(spacing: 4) {
                                Text("今日 \(todayMinutes) / \(dailyGoalMinutes) 分钟")
                                    .font(.system(size: 11, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(palette.secondaryText)
                        }
                        Spacer()
                        if goalReached {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("已达成")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(palette.sage)
                        }
                    }
                    // Custom progress rail: theme-tinted track + warm reading-time
                    // fill. SwiftUI's default ProgressView track rendered as a
                    // cold grey bar on the ink theme — explicit colors fix that.
                    // The fill carries a subtle theme-tinted glow that reinforces
                    // the same accent without lighting up like a status bar.
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(palette.progressTrack)
                            Capsule()
                                .fill(palette.readingTime)
                                .frame(width: max(0, proxy.size.width * dailyProgress))
                                .shadow(color: palette.glow.opacity(0.32), radius: 4, x: 0, y: 1)
                        }
                    }
                    .frame(height: 6)
                }
            } else {
                Menu {
                    dailyGoalMenuItems
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "target")
                            .font(.system(size: 11, weight: .bold))
                        Text("设定今日目标")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(palette.readingTime)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(palette.readingTime.opacity(0.16)))
                    .overlay(Capsule().stroke(palette.readingTime.opacity(0.28), lineWidth: 0.7))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: palette.heroGradient,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: palette.shadow, radius: 14, x: 0, y: 7)
    }

    @ViewBuilder
    private var dailyGoalMenuItems: some View {
        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { value in
            Button {
                dailyGoalMinutes = value
            } label: {
                if value == dailyGoalMinutes {
                    Label("\(value) 分钟", systemImage: "checkmark")
                } else {
                    Text("\(value) 分钟")
                }
            }
        }
        if dailyGoalMinutes > 0 {
            Divider()
            Button("清除目标", role: .destructive) {
                dailyGoalMinutes = 0
            }
        }
    }

    private var globalMetrics: some View {
        StatMetricStrip(
            metrics: [
                StatMetric(title: "总时长", value: formatMetricDuration(totalDuration), icon: "clock.fill", tint: palette.readingTime),
                StatMetric(title: "读过/读完", value: "\(readBookCount)本/\(finishedBookCount)本", icon: "books.vertical.fill", tint: palette.clay),
                StatMetric(title: "翻页数", value: formatCount(totalPages), icon: "arrow.turn.up.right", tint: palette.sage)
            ]
        )
    }

    private var rangePicker: some View {
        Picker("时间范围", selection: $selectedRange) {
            ForEach(StatsRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    private var periodSummary: some View {
        let duration = periodEvents.reduce(0) { $0 + $1.durationSeconds }
        let pages = periodEvents.reduce(0) { $0 + $1.pageTurns }
        let characters = periodEvents.reduce(0) { $0 + $1.characterCount }
        let speed: Double = duration >= 60 ? Double(pages) / (duration / 60) : 0
        let hasPeriodData = duration > 0 || pages > 0 || characters > 0

        // Always render the pill row — even with no data, fall back to "—" so the
        // 日/月/年 cards keep the same three-row layout (header / pills / commentary)
        // and end up at identical heights regardless of which range is selected.
        // The icon is in a fixed-size frame because SF Symbols like `sun.max.fill`,
        // `calendar`, and `chart.bar.xaxis` have slightly different intrinsic heights —
        // letting `Label` size itself causes a few-pixel header-height drift between ranges.
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: selectedRange.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.sage)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(palette.sage.opacity(0.18)))
                Text(selectedRange.reportTitle)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
                Text(formatDuration(duration))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.readingTime)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(height: 28)

            HStack(spacing: 10) {
                SmallStatPill(title: "阅读步调", value: hasPeriodData && speed > 0 ? String(format: "%.1f 页/分", speed) : "—", tint: palette.inkBlue)
                SmallStatPill(title: "字数", value: hasPeriodData ? formatCharacterCount(characters) : "—", tint: palette.clay)
                SmallStatPill(title: "翻页", value: hasPeriodData ? formatCount(pages) : "—", tint: palette.sage)
            }

            Text(hasPeriodData ? rangeCommentary(for: selectedRange) : emptyPeriodHint(for: selectedRange))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: 18)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCard()
    }

    private var trendCard: some View {
        let points = trendPoints(for: selectedRange)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("时段轨迹")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                Text(selectedRange.trendExplanation)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
            }

            StatsTrendChart(
                points: points,
                selectedPointID: $selectedTrendPointID,
                hasReadingData: hasAnyReadingData
            )
        }
        .padding(16)
        .statsCard()
        .animation(.easeInOut(duration: 0.18), value: selectedTrendPointID)
    }

    private var streakCalendarCard: some View {
        let monthStart = calendar.dateInterval(of: .month, for: displayedCalendarMonth)?.start ?? displayedCalendarMonth
        let summaries = monthlySummaries(containing: monthStart)
        let streak = currentStreak(days: dailySummaries(days: 120))
        let longestStreak = longestStreak()
        let activeDays = summaries.filter { summary in
            calendar.isDate(summary.day, equalTo: monthStart, toGranularity: .month) && summary.durationSeconds > 0
        }.count
        let canMoveForwardMonth = (calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart) <= currentMonthStart
        let canMoveForwardYear = (calendar.date(byAdding: .year, value: 1, to: monthStart) ?? monthStart) <= currentMonthStart
        let months = availableCalendarMonths
        let isCurrentMonth = calendar.isDate(monthStart, equalTo: currentMonthStart, toGranularity: .month)
        let activeDaysLabel = isCurrentMonth ? "本月阅读" : "\(calendar.component(.month, from: monthStart))月阅读"
        let weekRows = weeksInMonth(containing: monthStart)
        let calendarHeight: CGFloat = 22 + CGFloat(weekRows) * 43

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("阅读日历")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                Text("记录每一次沉浸")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
            }

            HStack(spacing: 10) {
                SmallStatPill(title: "当前连续", value: "\(streak) 天", tint: palette.gold)
                SmallStatPill(title: "最长连续", value: "\(longestStreak) 天", tint: palette.gold)
                SmallStatPill(title: activeDaysLabel, value: "\(activeDays) 天", tint: palette.sage)
            }

            HStack(spacing: 8) {
                CalendarNavigationButton(systemName: "chevron.left.2") {
                    moveDisplayedCalendar(by: -1, component: .year)
                }

                CalendarNavigationButton(systemName: "chevron.left") {
                    moveDisplayedCalendar(by: -1, component: .month)
                }

                Text(monthTitle(monthStart))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .frame(maxWidth: .infinity)

                CalendarNavigationButton(systemName: "chevron.right", isEnabled: canMoveForwardMonth) {
                    moveDisplayedCalendar(by: 1, component: .month)
                }

                CalendarNavigationButton(systemName: "chevron.right.2", isEnabled: canMoveForwardYear) {
                    moveDisplayedCalendar(by: 1, component: .year)
                }
            }

            TabView(selection: $displayedCalendarMonth) {
                ForEach(months, id: \.self) { month in
                    VStack(spacing: 0) {
                        StatsMonthlyReadingCalendar(
                            month: month,
                            summaries: monthlySummaries(containing: month),
                            dayTitle: dayTitle
                        )
                        .padding(.horizontal, 2)
                        Spacer(minLength: 0)
                    }
                    .tag(month)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: calendarHeight)
            .animation(.easeInOut(duration: 0.22), value: calendarHeight)

            HStack(spacing: 6) {
                Circle()
                    .fill(palette.readingAccent.opacity(0.95))
                    .frame(width: 7, height: 7)
                Text("有颜色代表当天读过，描边为今天")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            }
        }
        .padding(16)
        .statsCard()
    }

    private var heatmapCard: some View {
        let summaries = weeklyHeatmapSummaries()
        let today = calendar.startOfDay(for: Date())
        let maxDuration = max(summaries.map(\.durationSeconds).max() ?? 1, 1)
        let selectedSummary = selectedHeatmapDay.flatMap { selectedDay in
            summaries.first { calendar.isDate($0.day, inSameDayAs: selectedDay) }
        }
        let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("阅读热力")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                Text("记录近 12 周阅读状态")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
            }

            if hasAnyReadingData {
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 4) {
                        ForEach(weekdayLabels, id: \.self) { label in
                            Text(label)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 14)
                                .frame(maxHeight: .infinity)
                        }
                    }

                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { weekday in
                            HStack(spacing: 4) {
                                ForEach(0..<12, id: \.self) { week in
                                    let summary = summaries[weekday * 12 + week]
                                    let isFuture = summary.day > today
                                    let isSelected = !isFuture && (selectedHeatmapDay.map { calendar.isDate($0, inSameDayAs: summary.day) } ?? false)
                                    let level = isFuture ? 0 : heatLevel(summary.durationSeconds, maxDuration: maxDuration)
                                    let hasData = level > 0
                                    Button {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                            selectedHeatmapDay = isSelected ? nil : summary.day
                                        }
                                    } label: {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isFuture ? Color.clear : palette.heatLevels[level])
                                            .aspectRatio(1, contentMode: .fit)
                                            .frame(maxWidth: .infinity)
                                            // Filled cells get a hairline inner stroke so each block
                                            // reads as its own swatch instead of bleeding into neighbors.
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(hasData ? palette.primaryText.opacity(0.08) : .clear, lineWidth: 0.5)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(isSelected ? palette.primaryText.opacity(0.65) : .clear, lineWidth: 1.6)
                                            )
                                            // Uniform tiny theme-tinted depth on every active cell so
                                            // the heatmap reads as intentional / sculpted; selection
                                            // promotes to a tighter, stronger lift.
                                            .shadow(
                                                color: isSelected
                                                    ? palette.primaryText.opacity(0.18)
                                                    : (hasData ? palette.glow.opacity(0.10) : .clear),
                                                radius: isSelected ? 5 : 2,
                                                x: 0,
                                                y: isSelected ? 2 : 1
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isFuture)
                                    .opacity(isFuture ? 0 : 1)
                                    .accessibilityLabel("\(dayTitle(summary.day)) \(formatDuration(summary.durationSeconds))")
                                }
                            }
                        }
                    }
                }

                // Legend uses the strongest-level color at an opacity ramp so the
                // progression reads as one elegant arc (subtle → full) instead of
                // five distinct hues fighting for attention. Text is softened so
                // the legend recedes against the card.
                let legendOpacities: [Double] = [0.18, 0.36, 0.52, 0.72, 1.0]
                HStack(spacing: 6) {
                    Text("投入较少")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.secondaryText.opacity(0.78))
                    ForEach(legendOpacities.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(palette.heatLevels[4].opacity(legendOpacities[index]))
                            .frame(width: 16, height: 8)
                    }
                    Text("投入充足")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.secondaryText.opacity(0.78))
                    Spacer()
                }

                if let selectedSummary {
                    StatsSelectionPill(
                        icon: "calendar",
                        title: dayTitle(selectedSummary.day),
                        value: formatDuration(selectedSummary.durationSeconds),
                        detail: "\(formatCount(selectedSummary.pageTurns)) 页 · \(formatCharacterCount(selectedSummary.characterCount))",
                        tint: palette.readingAccent
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                Text("近 12 周还没有阅读记录。开始阅读后，这里会显示你的节奏。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(16)
        .statsLowerCard()
        .animation(.easeInOut(duration: 0.18), value: selectedHeatmapDay)
    }

    private var topBooksCard: some View {
        let interval = selectedTopBooksRange.interval(containing: Date(), calendar: calendar)
        let events = libraryStore.readingStats.events.filter { interval.contains($0.timestamp) }
        let books = topBooks(from: events)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("阅读榜单")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                Text("按时长排序")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            }

            StatsSegmentedControl(
                selection: $selectedTopBooksRange,
                options: TopBooksRange.allCases,
                title: \.title
            )

            if books.isEmpty {
                Text("\(selectedTopBooksRange.title)还没有可统计的阅读记录。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            } else {
                ForEach(Array(books.prefix(5).enumerated()), id: \.element.id) { index, item in
                    let rankColor = palette.rankAccents[index % palette.rankAccents.count]
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(rankColor)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(rankColor.opacity(0.22)))
                            .overlay(Circle().stroke(rankColor.opacity(0.42), lineWidth: 0.8))

                        if let book = booksByID[item.id] {
                            StatsBookCover(book: book, width: 38, height: 54)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
                                if booksByID[item.id]?.isDeleted == true {
                                    RemovedFromLibraryBadge()
                                }
                            }
                            Text("\(formatDuration(item.durationSeconds)) · \(formatCount(item.pageTurns)) 页 · \(formatCharacterCount(item.characterCount))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(16)
        .statsLowerCard()
    }

    private func heroSubtitle(minutes: Int, streak: Int) -> String {
        if minutes == 0 {
            return "翻开下一页后，这里会开始记录你的阅读节奏。"
        }
        if streak > 0 {
            return "已连续阅读 \(streak) 天，累计 \(formatCharacterCount(totalCharacters))。"
        }
        return "已累计 \(formatCharacterCount(totalCharacters))，今天再开个头吧。"
    }

    private func emptyPeriodHint(for range: StatsRange) -> String {
        switch range {
        case .day: return "今天还没开读。翻几页后，这里会热闹起来。"
        case .month: return "本月还没读，先选一本翻几页吧。"
        case .year: return "今年还没读，先选一本开个头吧。"
        }
    }

    /// Pick a copy line from the bank by mixing the period seed through a hash so
    /// consecutive periods don't fall on consecutive bank indices. The pick is still
    /// deterministic per day / month / year, so the line stays stable across view
    /// re-renders within the same period — it just no longer marches through the list
    /// in order.
    private func rangeCommentary(for range: StatsRange) -> String {
        let bank: [String]
        let seed: Int
        let now = Date()
        switch range {
        case .day:
            bank = StatsCommentary.daily
            seed = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        case .month:
            bank = StatsCommentary.monthly
            seed = calendar.component(.year, from: now) * 100
                + calendar.component(.month, from: now)
        case .year:
            bank = StatsCommentary.yearly
            seed = calendar.component(.year, from: now)
        }
        guard !bank.isEmpty else { return "" }
        // SplitMix64 finalizer — well-distributed mix that scatters adjacent seeds.
        var x = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x = x ^ (x >> 31)
        return bank[Int(x % UInt64(bank.count))]
    }

    private func weeksInMonth(containing date: Date) -> Int {
        let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let daysToMonthEnd = calendar.dateComponents([.day], from: gridStart, to: monthEnd).day ?? 30
        return max(1, Int(ceil(Double(daysToMonthEnd) / 7.0)))
    }

    private func trendPoints(for range: StatsRange) -> [TrendPoint] {
        switch range {
        case .day:
            return (0..<24).map { hour in
                let seconds = periodEvents
                    .filter { calendar.component(.hour, from: $0.timestamp) == hour }
                    .reduce(0) { $0 + $1.durationSeconds }
                return TrendPoint(
                    id: "hour-\(hour)",
                    label: hour % 4 == 0 ? "\(hour) 点" : "",
                    title: "\(hour):00",
                    date: Date(),
                    durationSeconds: seconds
                )
            }
        case .month:
            let start = range.interval(containing: Date(), calendar: calendar).start
            let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
            return (0..<dayCount).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                let seconds = periodEvents
                    .filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
                    .reduce(0) { $0 + $1.durationSeconds }
                return TrendPoint(
                    id: "day-\(offset + 1)",
                    label: offset % 5 == 0 ? "\(offset + 1)日" : "",
                    title: dayTitle(date),
                    date: date,
                    durationSeconds: seconds
                )
            }
        case .year:
            let start = range.interval(containing: Date(), calendar: calendar).start
            return (0..<12).map { offset in
                let date = calendar.date(byAdding: .month, value: offset, to: start) ?? start
                let seconds = periodEvents
                    .filter { calendar.component(.month, from: $0.timestamp) == offset + 1 }
                    .reduce(0) { $0 + $1.durationSeconds }
                return TrendPoint(
                    id: "month-\(offset + 1)",
                    label: offset.isMultiple(of: 2) ? "\(offset + 1)月" : "",
                    title: "\(offset + 1)月",
                    date: date,
                    durationSeconds: seconds
                )
            }
        }
    }

    private func weeklyHeatmapSummaries() -> [DailyReadingSummary] {
        let today = calendar.startOfDay(for: Date())
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstColumnStart = calendar.date(byAdding: .day, value: -11 * 7, to: currentWeekStart) ?? today
        var summaries: [DailyReadingSummary] = []
        summaries.reserveCapacity(7 * 12)
        for weekday in 0..<7 {
            for week in 0..<12 {
                let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: firstColumnStart) ?? firstColumnStart
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let events = libraryStore.readingStats.events.filter { $0.timestamp >= day && $0.timestamp < nextDay }
                summaries.append(
                    DailyReadingSummary(
                        day: day,
                        durationSeconds: events.reduce(0) { $0 + $1.durationSeconds },
                        pageTurns: events.reduce(0) { $0 + $1.pageTurns },
                        characterCount: events.reduce(0) { $0 + $1.characterCount },
                        topBookID: nil
                    )
                )
            }
        }
        return summaries
    }

    private func dailySummaries(days count: Int) -> [DailyReadingSummary] {
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let events = libraryStore.readingStats.events.filter { $0.timestamp >= day && $0.timestamp < nextDay }
            return DailyReadingSummary(
                day: day,
                durationSeconds: events.reduce(0) { $0 + $1.durationSeconds },
                pageTurns: events.reduce(0) { $0 + $1.pageTurns },
                characterCount: events.reduce(0) { $0 + $1.characterCount },
                topBookID: nil
            )
        }
    }

    private func monthlySummaries(containing date: Date) -> [DailyReadingSummary] {
        let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let daysToMonthEnd = calendar.dateComponents([.day], from: gridStart, to: monthEnd).day ?? 30
        let weeksNeeded = max(1, Int(ceil(Double(daysToMonthEnd) / 7.0)))
        let totalDays = weeksNeeded * 7
        return (0..<totalDays).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: gridStart) ?? gridStart
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let events = libraryStore.readingStats.events.filter { $0.timestamp >= day && $0.timestamp < nextDay }
            return DailyReadingSummary(
                day: day,
                durationSeconds: events.reduce(0) { $0 + $1.durationSeconds },
                pageTurns: events.reduce(0) { $0 + $1.pageTurns },
                characterCount: events.reduce(0) { $0 + $1.characterCount },
                topBookID: nil
            )
        }
    }

    private func topBookID(in events: [ReadingStatsEvent]) -> UUID? {
        topBooks(from: events).first?.id
    }

    private func topBooks(from events: [ReadingStatsEvent]) -> [BookReadingAggregate] {
        let grouped = Dictionary(grouping: events, by: \.bookID)
        return grouped.compactMap { bookID, events in
            let title = booksByID[bookID]?.title ?? events.last?.bookTitle ?? "未知书籍"
            return BookReadingAggregate(
                id: bookID,
                title: title,
                durationSeconds: events.reduce(0) { $0 + $1.durationSeconds },
                pageTurns: events.reduce(0) { $0 + $1.pageTurns },
                characterCount: events.reduce(0) { $0 + $1.characterCount }
            )
        }
        .sorted {
            if $0.durationSeconds != $1.durationSeconds {
                return $0.durationSeconds > $1.durationSeconds
            }
            return $0.pageTurns > $1.pageTurns
        }
    }

    private func currentStreak(days: [DailyReadingSummary]) -> Int {
        var streak = 0
        for summary in days.reversed() {
            if summary.durationSeconds > 0 {
                streak += 1
            } else if !calendar.isDateInToday(summary.day) {
                break
            }
        }
        return streak
    }

    private func longestStreak() -> Int {
        let activeDays = Set(libraryStore.readingStats.events.map { calendar.startOfDay(for: $0.timestamp) })
        guard !activeDays.isEmpty else { return 0 }
        let sorted = activeDays.sorted()
        var longest = 1
        var run = 1
        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let current = sorted[index]
            let nextDay = calendar.date(byAdding: .day, value: 1, to: previous) ?? previous
            if calendar.isDate(current, inSameDayAs: nextDay) {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }
        return longest
    }

    /// Quantizes a duration into one of the palette's 5 fixed heat levels so the
    /// heatmap reads as discrete intensity steps (matching the legend swatches) rather
    /// than a continuous gradient where adjacent cells look almost identical.
    private func heatColor(_ duration: TimeInterval, maxDuration: TimeInterval) -> Color {
        palette.heatLevels[heatLevel(duration, maxDuration: maxDuration)]
    }

    private func heatLevel(_ duration: TimeInterval, maxDuration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let normalized = min(max(duration / maxDuration, 0), 1)
        // Map (0, 1] → indices 1...4 (level 0 is reserved for "no reading").
        return min(4, max(1, Int(ceil(normalized * 4))))
    }

    private func moveDisplayedCalendar(by value: Int, component: Calendar.Component) {
        let monthStart = calendar.dateInterval(of: .month, for: displayedCalendarMonth)?.start ?? displayedCalendarMonth
        let proposed = calendar.date(byAdding: component, value: value, to: monthStart) ?? monthStart
        displayedCalendarMonth = min(proposed, currentMonthStart)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        if minutes < 60 { return "\(minutes) 分钟" }
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let remainder = minutes % 60

        if days > 0 {
            var parts = ["\(days)天"]
            if hours > 0 { parts.append("\(hours)小时") }
            if remainder > 0 { parts.append("\(remainder)分钟") }
            return parts.joined()
        }

        return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分"
    }

    private func formatMetricDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        if minutes < 60 { return "\(minutes)分钟" }

        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let remainder = minutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)天\(hours)小时" : "\(days)天"
        }

        return remainder == 0 ? "\(hours)小时" : "\(hours)小时\(remainder)分"
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 100_000_000 {
            return formatChineseUnit(Double(value) / 100_000_000, unit: "亿")
        }
        if value >= 10_000 {
            return formatChineseUnit(Double(value) / 10_000, unit: "万")
        }
        return "\(value)"
    }

    private func formatCharacterCount(_ value: Int) -> String {
        "\(formatCount(value))字"
    }

    private func formatChineseUnit(_ value: Double, unit: String) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))\(unit)"
        }
        return String(format: "%.1f%@", rounded, unit)
    }

    private func dayTitle(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    private func monthTitle(_ date: Date) -> String {
        Self.monthFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()
}

private enum StatsRange: String, CaseIterable, Identifiable {
    case day
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "日"
        case .month: return "月"
        case .year: return "年"
        }
    }

    var reportTitle: String {
        switch self {
        case .day: return "今日阅读小结"
        case .month: return "本月阅读回顾"
        case .year: return "年度阅读复盘"
        }
    }

    var trendExplanation: String {
        switch self {
        case .day: return "当日阅读分布"
        case .month: return "本月每日分布"
        case .year: return "全年每月分布"
        }
    }

    var systemImage: String {
        switch self {
        case .day: return "sun.max.fill"
        case .month: return "calendar"
        case .year: return "chart.bar.xaxis"
        }
    }

    func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component
        switch self {
        case .day: component = .day
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: date, duration: 24 * 60 * 60)
    }
}

private enum TopBooksRange: String, CaseIterable, Identifiable {
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "本周"
        case .month: return "本月"
        case .year: return "本年"
        }
    }

    func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component
        switch self {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: date, duration: 7 * 24 * 60 * 60)
    }
}

private struct TrendPoint: Identifiable {
    let id: String
    let label: String
    let title: String
    let date: Date
    let durationSeconds: TimeInterval
}

private struct DailyReadingSummary: Identifiable {
    var id: Date { day }
    let day: Date
    let durationSeconds: TimeInterval
    let pageTurns: Int
    let characterCount: Int
    let topBookID: UUID?
}

private struct BookReadingAggregate: Identifiable {
    let id: UUID
    let title: String
    let durationSeconds: TimeInterval
    let pageTurns: Int
    let characterCount: Int
}

private struct StatMetric: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    let icon: String
    /// Optional per-metric tint for the icon chip. When nil, defaults to the
    /// theme accent so metrics introduced without explicit color still look reasonable.
    var tint: Color? = nil
}

private struct StatMetricStrip: View {
    @Environment(\.statsPalette) private var palette
    let metrics: [StatMetric]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                StatMetricColumn(metric: metric)
                    .frame(maxWidth: .infinity)

                if index < metrics.count - 1 {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(width: 1, height: 52)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .statsCard()
    }
}

private struct StatMetricColumn: View {
    @Environment(\.statsPalette) private var palette
    let metric: StatMetric

    var body: some View {
        let tint = metric.tint ?? palette.readingTime
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: metric.icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint.opacity(0.18)))

                Text(metric.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Text(metric.value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmallStatPill: View {
    @Environment(\.statsPalette) private var palette
    let title: String
    let value: String
    /// Optional accent that tints the value text + a subtle background wash. Lets
    /// each pill in a row carry a different semantic role (pace / words / pages).
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tint ?? palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((tint ?? palette.secondaryText).opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke((tint ?? palette.secondaryText).opacity(0.38), lineWidth: 0.8)
        )
    }
}

/// Sakura-tuned segmented control: soft theme-tinted track, near-white active pill
/// with a diffused glow, and a spring-animated slide between segments. Replaces the
/// stock `.segmented` Picker which read as too utilitarian for the literary tone.
private struct StatsSegmentedControl<Value: Hashable & Identifiable>: View {
    @Environment(\.statsPalette) private var palette
    @Binding var selection: Value
    let options: [Value]
    let title: KeyPath<Value, String>

    var body: some View {
        GeometryReader { proxy in
            let count = max(options.count, 1)
            let trackHeight: CGFloat = 34
            let segmentWidth = proxy.size.width / CGFloat(count)
            let selectedIndex = options.firstIndex(where: { $0 == selection }) ?? 0

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.segmentedTrack)
                    .frame(height: trackHeight)

                Capsule(style: .continuous)
                    .fill(palette.segmentedActive)
                    .frame(width: segmentWidth - 6, height: trackHeight - 6)
                    .shadow(color: palette.glow.opacity(0.10), radius: 16, x: 0, y: 6)
                    .offset(x: segmentWidth * CGFloat(selectedIndex) + 3)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selection)

                HStack(spacing: 0) {
                    ForEach(options) { option in
                        let isActive = option == selection
                        Button {
                            selection = option
                        } label: {
                            Text(option[keyPath: title])
                                .font(.system(size: 13, weight: isActive ? .semibold : .medium, design: .rounded))
                                .foregroundStyle(isActive ? palette.primaryText : palette.secondaryText)
                                .frame(maxWidth: .infinity)
                                .frame(height: trackHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: trackHeight)
        }
        .frame(height: 34)
    }
}

private struct StatsTrendChart: View {
    @Environment(\.statsPalette) private var palette
    let points: [TrendPoint]
    @Binding var selectedPointID: String?
    var hasReadingData: Bool = true

    private let topInset: CGFloat = 28
    private let plotHeight: CGFloat = 108
    private let axisLabelHeight: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let axisY = topInset + plotHeight
            let maxValue = max(points.map(\.durationSeconds).max() ?? 1, 1)

            ZStack(alignment: .topLeading) {
                if hasReadingData {
                    // Three airy gridlines that quietly mark the plot rhythm without
                    // boxing the bars in. Baseline gets ~1.6x opacity so the chart
                    // still reads as a real chart when only one bar is visible.
                    Rectangle()
                        .fill(palette.chartGridLine.opacity(0.35))
                        .frame(height: 0.5)
                        .position(x: width / 2, y: topInset + plotHeight * 0.33)
                    Rectangle()
                        .fill(palette.chartGridLine.opacity(0.35))
                        .frame(height: 0.5)
                        .position(x: width / 2, y: topInset + plotHeight * 0.66)
                    Rectangle()
                        .fill(palette.chartGridLine.opacity(0.65))
                        .frame(height: 0.6)
                        .position(x: width / 2, y: axisY)

                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if !point.label.isEmpty {
                            let x = xPosition(for: index, width: width)
                            Text(point.label)
                                .font(.system(size: 10, weight: selectedPointID == point.id ? .bold : .semibold, design: .rounded))
                                .foregroundStyle(selectedPointID == point.id ? palette.readingTime : palette.secondaryText)
                                .frame(width: 46)
                                .position(x: clamped(x, minimum: 23, maximum: width - 23), y: axisY + 15)
                        }
                    }
                }

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    // Bars render only for buckets that show as ≥1 minute. Otherwise a few-second
                    // bucket would display as "0 分钟" in the tooltip yet still draw a visible
                    // bar (and, because the 8pt floor doesn't apply to slightly-larger sub-minute
                    // values, two "0 分钟" buckets could even render at different heights).
                    if hasReadingData && Int(point.durationSeconds / 60) >= 1 {
                        let x = xPosition(for: index, width: width)
                        let height = barHeight(for: point.durationSeconds, maxValue: maxValue)
                        let isSelected = selectedPointID == point.id
                        let top = palette.chartGradient.first ?? palette.readingTime
                        let bottom = palette.chartGradient.last ?? palette.readingTime

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                selectedPointID = point.id
                            }
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            top.opacity(isSelected ? 1 : 0.92),
                                            bottom.opacity(isSelected ? 0.88 : 0.70)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: barWidth, height: height)
                                // Cinematic, blurred glow: every bar carries a quiet
                                // ambient halo so the trend feels luminous; selected
                                // bar lifts into a stronger, tighter aura.
                                .shadow(
                                    color: isSelected
                                        ? palette.glow.opacity(0.42)
                                        : palette.glow.opacity(0.14),
                                    radius: isSelected ? 7 : 4,
                                    x: 0,
                                    y: isSelected ? 2 : 1
                                )
                                .frame(width: tapWidth, height: plotHeight, alignment: .bottom)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .position(x: x, y: topInset + plotHeight / 2)
                        .accessibilityLabel("\(point.title) \(compactDuration(point.durationSeconds))")
                    }
                }

                if let selected = selectedPoint(in: points),
                   let index = points.firstIndex(where: { $0.id == selected.id }),
                   Int(selected.durationSeconds / 60) >= 1 {
                    let x = xPosition(for: index, width: width)
                    let height = barHeight(for: selected.durationSeconds, maxValue: maxValue)
                    Text(compactDuration(selected.durationSeconds))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.readingTime)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(palette.surfaceElevated))
                        .overlay(Capsule().stroke(palette.border, lineWidth: 0.6))
                        .shadow(color: palette.shadow, radius: 5, x: 0, y: 2)
                        .fixedSize()
                        .position(
                            x: clamped(x, minimum: 28, maximum: width - 28),
                            y: max(10, topInset + plotHeight - height - 13)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .frame(height: topInset + plotHeight + axisLabelHeight)
    }

    private var barWidth: CGFloat {
        if points.count <= 12 { return 11 }
        if points.count <= 24 { return 7 }
        return 4
    }

    private var tapWidth: CGFloat {
        max(barWidth + 14, 22)
    }

    private func barHeight(for value: TimeInterval, maxValue: TimeInterval) -> CGFloat {
        max(CGFloat(value / maxValue) * plotHeight, 8)
    }

    private func xPosition(for index: Int, width: CGFloat) -> CGFloat {
        guard points.count > 1 else { return width / 2 }
        let sideInset = max(tapWidth / 2, 8)
        let usableWidth = max(width - sideInset * 2, 1)
        return sideInset + usableWidth * CGFloat(index) / CGFloat(points.count - 1)
    }

    private func selectedPoint(in points: [TrendPoint]) -> TrendPoint? {
        points.first { $0.id == selectedPointID }
    }

    private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), max(minimum, maximum))
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分钟"
    }
}

private struct StatsSelectionPill: View {
    @Environment(\.statsPalette) private var palette
    let icon: String
    let title: String
    let value: String
    let detail: String
    var tint: Color? = nil

    var body: some View {
        let accent = tint ?? palette.inkBlue

        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(accent.opacity(0.18)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.surfaceMuted)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CalendarNavigationButton: View {
    @Environment(\.statsPalette) private var palette
    let systemName: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isEnabled ? palette.primaryText : palette.secondaryText.opacity(0.45))
                .frame(width: 34, height: 30)
                .background(palette.surfaceMuted.opacity(isEnabled ? 1 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.border, lineWidth: 0.6)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct StatsMonthlyReadingCalendar: View {
    @Environment(\.statsPalette) private var palette
    let month: Date
    let summaries: [DailyReadingSummary]
    let dayTitle: (Date) -> String
    private let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }()

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    }

    var body: some View {
        VStack(spacing: 7) {
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(weekdayTitles, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity)
                }

                ForEach(summaries) { summary in
                    let isCurrentMonth = calendar.isDate(summary.day, equalTo: month, toGranularity: .month)
                    CalendarDayCell(
                        summary: summary,
                        isCurrentMonth: isCurrentMonth
                    )
                    .accessibilityLabel(accessibilityLabel(for: summary, isCurrentMonth: isCurrentMonth))
                }
            }
        }
    }

    private var weekdayTitles: [String] {
        ["一", "二", "三", "四", "五", "六", "日"]
    }

    private func accessibilityLabel(for summary: DailyReadingSummary, isCurrentMonth: Bool) -> String {
        guard isCurrentMonth else {
            return "\(dayTitle(summary.day)) 非本月"
        }
        if summary.durationSeconds > 0 {
            return "\(dayTitle(summary.day)) 有阅读"
        }
        return "\(dayTitle(summary.day)) 没有阅读记录"
    }
}

private struct CalendarDayCell: View {
    @Environment(\.statsPalette) private var palette
    let summary: DailyReadingSummary
    let isCurrentMonth: Bool
    private let calendar = Calendar.current

    var body: some View {
        let hasRead = summary.durationSeconds > 0
        let isToday = calendar.isDateInToday(summary.day)

        VStack(spacing: 3) {
            Text("\(calendar.component(.day, from: summary.day))")
                .font(.system(size: 11, weight: hasRead ? .bold : .semibold, design: .rounded))
                .foregroundStyle(textColor(hasRead: hasRead, isToday: isToday))

            Capsule()
                .fill(hasRead && isCurrentMonth ? palette.readingAccent.opacity(0.95) : .clear)
                .frame(width: 14, height: 3)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor(hasRead: hasRead, isToday: isToday))
                // Cinematic, blurred ambient glow only under read days in the current
                // month. Theme-tinted via palette.glow so Sakura reads as rose,
                // Forest as moss, etc. — never neon.
                .shadow(
                    color: (hasRead && isCurrentMonth) ? palette.glow.opacity(0.22) : .clear,
                    radius: 6,
                    x: 0,
                    y: 1
                )
        )
        .overlay(
            // Inset the stroke so it sits inside the rounded background rather than getting
            // half-clipped by the cell's outer edge.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .inset(by: 0.6)
                .stroke(borderColor(hasRead: hasRead, isToday: isToday), lineWidth: borderWidth(isToday: isToday))
        )
        .opacity(isCurrentMonth ? 1 : 0.34)
    }

    private func backgroundColor(hasRead: Bool, isToday: Bool) -> Color {
        guard isCurrentMonth else {
            return palette.surfaceMuted.opacity(0.45)
        }
        // Read days pull the theme-aware reading accent so the calendar speaks
        // the same color language as the heatmap, just softer. Today is marked
        // by the stronger outline ring — not a darker fill — so a streak still
        // reads as one consistent swatch.
        if hasRead {
            return palette.readingAccent.opacity(0.42)
        }
        return palette.surfaceMuted.opacity(0.75)
    }

    private func textColor(hasRead: Bool, isToday: Bool) -> Color {
        guard isCurrentMonth else {
            return palette.secondaryText.opacity(0.55)
        }
        if hasRead {
            return palette.primaryText
        }
        return palette.secondaryText.opacity(0.82)
    }

    private func borderColor(hasRead: Bool, isToday: Bool) -> Color {
        if isToday { return palette.primaryText.opacity(0.88) }
        if hasRead { return palette.readingAccent.opacity(0.68) }
        return .clear
    }

    private func borderWidth(isToday: Bool) -> CGFloat {
        isToday ? 1.8 : 0.6
    }
}

private struct StatsBookCover: View {
    let book: ReadingStatsBook
    let width: CGFloat
    let height: CGFloat
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            coverBackground

            Text(displayed(book.title))
                .font(.system(size: 10, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.65)
                .padding(6)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let coverImageURLString = book.coverImageURLString,
           let url = URL(string: coverImageURLString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .overlay(Color.black.opacity(0.24))
                default:
                    fallbackCover
                }
            }
        } else {
            fallbackCover
        }
    }

    private var fallbackCover: some View {
        LinearGradient(
            colors: [book.coverPalette.color.opacity(0.96), book.coverPalette.color.opacity(0.68)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

/// Copy banks for the 阅读小结 / 回顾 / 复盘 subtitle line under each report card.
/// `rangeCommentary(for:)` picks one entry per period using a date-derived seed, so the
/// chosen line is stable within a day / month / year and drifts naturally across periods.
private enum StatsCommentary {
    static let daily: [String] = [
        "阅读步调稳定，在文字里从容沉浸。",
        "专注阅读的时刻，都在悄悄沉淀自我。",
        "保持舒适节奏，享受属于自己的阅读时光。",
        "今日阅读状态在线，稳步积累，自在随心。",
        "沉浸文字之中，收获片刻安静与充实。",
        "阅读节奏松弛有度，享受沉浸式阅读体验。",
        "阅读节奏在线，沉浸式体验拉满。",
        "今日阅读状态稳定，专注感拉满。",
        "高效完成阅读输入，氛围感十足。",
        "把碎片时间，变成专属阅读时刻。",
        "阅读效率稳定，精神补给到位。",
        "今日阅读打卡成功，状态持续在线。",
        "沉浸感刚刚好，阅读体验很舒服。",
        "稳步阅读，给自己充好精神电量。"
    ]

    static let monthly: [String] = [
        "持续保持阅读节奏，在积累中收获充实。",
        "一月的点滴坚持，汇聚成独有的阅读印记。",
        "稳步深耕阅读，让文字陪伴日常点滴。",
        "本月阅读节奏稳定，长期积累看得见。",
        "坚持阅读一整月，氛围感持续在线。",
        "本月阅读习惯养成，状态保持得很好。",
        "日复一日的阅读，悄悄拉开差距。",
        "月度阅读续航稳定，收获满满。"
    ]

    static let yearly: [String] = [
        "长久的阅读坚持，沉淀出独属于你的精神世界。",
        "以书为伴，以读为常，时光自有答案。",
        "经年累月的阅读，终将成为内在的底气。",
        "一整年的阅读沉淀，气质自然流露。",
        "长期阅读坚持，内在储备持续升级。",
        "用一整年的阅读，完成自我充电。",
        "阅读这件事，你坚持得很有质感。",
        "常年保持阅读，本身就是一种实力。"
    ]
}
