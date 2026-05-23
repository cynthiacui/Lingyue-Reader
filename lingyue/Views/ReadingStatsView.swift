import SwiftUI
import UIKit

// MARK: - Editorial type system
//
// Mirrors the HTML mockup's `font-family: 'DM Serif Display', 'Noto Serif SC',
// serif` cascade. CSS picks DM Serif Display per-glyph for Latin/digits and
// falls through to Noto Serif SC for CJK; SwiftUI's `Font.custom(...)` doesn't
// fall back per-glyph on its own, so we build a UIFontDescriptor with an
// explicit `.cascadeList` that does the same thing — DM Serif Display draws
// "47", "32", "38", Roman numerals; Source Han Serif SC (思源宋体 = Noto Serif
// SC, already bundled for the reader) draws the Chinese glyphs in the same
// line. The result is one cohesive serif line where the didone Western digits
// pair with the matching CJK stroke axis the HTML mock has.

private enum LiteraryWeight {
    case light, regular, bold
}

private enum LiteraryFont {
    static func uiFont(latin: String, fallback: String, size: CGFloat, bold: Bool) -> UIFont {
        let primary = UIFontDescriptor(fontAttributes: [.name: latin])
        let secondary = UIFontDescriptor(fontAttributes: [.name: fallback])
        var descriptor = primary.addingAttributes([
            UIFontDescriptor.AttributeName.cascadeList: [secondary]
        ])
        if bold, let bolded = descriptor.withSymbolicTraits([.traitBold]) {
            descriptor = bolded
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension Font {
    /// Literary serif cascade — DM Serif Display (Latin / digits) backed by
    /// Source Han Serif SC (CJK). Drop-in for any focal numeral + Chinese-unit
    /// pair on the Stats tab (hero figure, period figure, stat columns, Roman
    /// numerals, section ordinals, book titles). The weight switch keeps the
    /// API surface identical for callers; .bold relies on SwiftUI's synthesized
    /// bold since neither bundled face ships heavier variants.
    fileprivate static func literarySerif(size: CGFloat, weight: LiteraryWeight = .regular) -> Font {
        Font(LiteraryFont.uiFont(
            latin: "DMSerifDisplay-Regular",
            fallback: "SourceHanSerifSC-Regular",
            size: size,
            bold: weight == .bold
        ))
    }

    /// Italic literary serif — DM Serif Display Italic for Latin/digits with
    /// the same Source Han Serif SC fallback. SwiftUI's `.italic()` synthesizes
    /// a slant on the fallback for any CJK glyphs in the run, matching the
    /// HTML's `font-style: italic` on Noto Serif SC commentary lines.
    fileprivate static func literarySerifItalic(size: CGFloat) -> Font {
        Font(LiteraryFont.uiFont(
            latin: "DMSerifDisplay-Italic",
            fallback: "SourceHanSerifSC-Regular",
            size: size,
            bold: false
        )).italic()
    }
}

/// Renders `string` in the italic literary serif, except ASCII number tokens
/// (e.g. "12", "1.2", "1,200") which fall back to the upright variant. Keeps
/// the Chinese kicker copy stylistically italic while preventing the slanted
/// DM Serif Display digits from sitting awkwardly inside a Songti line.
fileprivate func literarySerifItalicText(_ string: String, size: CGFloat) -> Text {
    let italic: Font = .literarySerifItalic(size: size)
    let upright: Font = .literarySerif(size: size)
    let pattern = #"\d+(?:[.,]\d+)*"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return Text(verbatim: string).font(italic)
    }
    let ns = string as NSString
    let matches = regex.matches(in: string, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else {
        return Text(verbatim: string).font(italic)
    }

    var result = Text(verbatim: "")
    var cursor = 0
    for match in matches {
        if match.range.location > cursor {
            let prefix = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result = result + Text(verbatim: prefix).font(italic)
        }
        let digits = ns.substring(with: match.range)
        result = result + Text(verbatim: digits).font(upright)
        cursor = match.range.location + match.range.length
    }
    if cursor < ns.length {
        let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        result = result + Text(verbatim: tail).font(italic)
    }
    return result
}

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

    /// Deep editorial accent used for the "壹/贰/叁/肆" section markers, the 印章
    /// streak seal on the hero card, and rank-1 Roman numerals in the leaderboard.
    /// Tuned to be one shade deeper than `gold` so section openings register as a
    /// "stamped" mark on the page (literary, not decorative). Theme-aware so Sakura
    /// reads as deep rose, Forest as deep moss, Ink as warm sepia.
    let sectionAccent: Color

    /// Color for the page's monumental serif figures — the hero "0 分钟" and the
    /// period card's 40pt duration. Normally tracks `primaryText` (a near-black
    /// editorial ink). For the Sakura theme it's painted in a deep warm
    /// mulberry-ink that's distinct from both the body type AND the cinnabar
    /// `sectionAccent` — completing the paper · ink · seal triad: blush paper
    /// background, mulberry-dark figure ink, scattered cinnabar seal accents.
    /// Earlier iterations painted the hero in cinnabar too, but that made the
    /// 60pt figure visually fungible with the small 阅读投入 kicker and 连读
    /// 印章 badge — size became the only differentiator instead of role.
    let heroFigure: Color

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
        let textPrimary = lightPrimaryText(for: theme)
        let textSecondary = lightSecondaryText(for: theme)
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
            // labels stay legible against the warm paper. Sakura pushes one shade
            // deeper than the other light themes so body type sits more firmly
            // against the blush wash instead of softening into the rose mid-tones.
            primaryText:      textPrimary,
            secondaryText:    textSecondary,
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
            segmentedActive:   Color.white.opacity(0.92),
            sectionAccent:     lightSectionAccent(for: theme),
            heroFigure:        lightHeroFigure(for: theme, primaryText: textPrimary)
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
            segmentedActive:   Color(red: 0.165, green: 0.196, blue: 0.298),
            sectionAccent:     Color(red: 0.784, green: 0.643, blue: 0.416), // #C8A46A ripe champagne — deeper than gold for stronger seal-stamp presence
            heroFigure:        Color(red: 0.96, green: 0.94, blue: 0.88)     // = primaryText; dark theme already has high contrast
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

    /// Editorial contrast accent — the cinnabar "印章" seal stamp role. This is
    /// intentionally NOT a deeper shade of each theme's own color (that gave
    /// every section marker the same green-on-green / rose-on-rose monotone
    /// the old version suffered from); it's a true complementary contrast.
    ///
    /// • paperGreen / leafGreen → 朱砂红 cinnabar — the classic Chinese book
    ///   triad of cream paper + green calligraphy + red seal stamp.
    /// • ink → 朱砂红 cinnabar — same warm-paper-and-seal combination.
    /// • pink → 胭脂深 deep rouge — reuses the app's existing 印章 seal red
    ///   (the same hue used by the 我-tab streak badge). Reading as deep
    ///   rouge-red on the blush page gives proper paper+seal contrast where
    ///   the previous warm-ink choice sat too close to body-text tone.
    /// • starryNight → 月华金 champagne — warm luminance against deep navy.
    private static func lightSectionAccent(for theme: AppTheme) -> Color {
        switch theme {
        case .pink:                            return Color(red: 0.600, green: 0.240, blue: 0.180) // #992F2E 胭脂深 deep rouge (app seal)
        case .ink:                             return Color(red: 0.722, green: 0.227, blue: 0.227) // #B83A3A 朱砂红 cinnabar
        case .paperGreen, .leafGreen:          return Color(red: 0.722, green: 0.227, blue: 0.227) // #B83A3A 朱砂红 cinnabar
        case .starryNight:                     return Color(red: 0.878, green: 0.769, blue: 0.561) // #E0C48F 月华金 champagne
        }
    }

    /// Body / heading ink. Sakura pushes one shade deeper because its blush wash
    /// reflects more light than the warm-cream surfaces the other light themes
    /// sit on — without this, the warm near-black softens into the rose mid-tones
    /// and the whole page reads monotone. Other themes keep the editorial
    /// warm-near-black that pairs with the cream paper aesthetic.
    private static func lightPrimaryText(for theme: AppTheme) -> Color {
        switch theme {
        case .pink:                            return Color(red: 0.075, green: 0.060, blue: 0.055) // #131011 deeper near-black
        case .ink, .paperGreen, .leafGreen, .starryNight:
                                               return Color(red: 0.105, green: 0.098, blue: 0.086) // #1B1916 warm editorial ink
        }
    }

    /// Secondary text — same per-theme push as primaryText: Sakura goes one
    /// shade deeper so kicker labels and commentary stay legible against the
    /// brighter blush page rather than blending into the rose family.
    private static func lightSecondaryText(for theme: AppTheme) -> Color {
        switch theme {
        case .pink:                            return Color(red: 0.298, green: 0.265, blue: 0.232) // #4C443B deeper warm grey
        case .ink, .paperGreen, .leafGreen, .starryNight:
                                               return Color(red: 0.355, green: 0.325, blue: 0.275) // #5B5346 warm grey-brown
        }
    }

    /// The monumental serif figure color — used by the hero "0 分钟" and the
    /// period card's 40pt duration. Sakura gets a 墨檀 deep warm mulberry-ink
    /// that's distinct from both the body type (`primaryText` — near-black) and
    /// the seal accents (`sectionAccent` — cinnabar): the hero is the dominant
    /// dark voice of the page, the cinnabar marks remain small seal punctuation.
    /// Other themes keep their primary ink (they already have plenty of
    /// figure/ground contrast against warm cream or deep indigo).
    private static func lightHeroFigure(for theme: AppTheme, primaryText: Color) -> Color {
        switch theme {
        case .pink:                            return Color(red: 0.180, green: 0.122, blue: 0.133) // #2E1F22 墨檀 deep mulberry-ink
        case .ink, .paperGreen, .leafGreen, .starryNight:
                                               return primaryText
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
        // Earlier this property scanned every reading event with `.min()` on
        // every Stats body render to figure out the earliest month worth
        // showing. With long-time users having thousands of events that scan
        // was on the hot path of every tab switch. Default to a fixed 24-month
        // window back from today; if the user has navigated to an even earlier
        // month, extend just enough to include it. The chevrons handle going
        // further back when needed.
        let defaultStart = calendar.date(byAdding: .month, value: -23, to: currentMonthStart) ?? currentMonthStart
        let earliest = min(defaultStart, displayedCalendarMonth)
        var months: [Date] = []
        var cursor = earliest
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
                // Compute the day-buckets once per body render and share with
                // every card that needs them. Each Stats render used to do
                // multiple full-events scans (calendar + heatmap + each month
                // page); a single shared map cuts that down to one pass.
                let buckets = bucketEventsByDay()
                VStack(alignment: .leading, spacing: bodySpacing) {
                    heroCard
                    globalMetrics
                    sectionHeader(num: "壹", title: "节奏", sub: "RHYTHM · NO.01")
                    rangePicker
                    periodSummary
                    sectionHeader(num: "贰", title: "日历", sub: "CALENDAR · NO.02")
                    streakCalendarCard(buckets: buckets)
                    sectionHeader(num: "叁", title: "热力", sub: "HEATMAP · NO.03")
                    heatmapCard(buckets: buckets)
                    sectionHeader(num: "肆", title: "旅程", sub: "JOURNEY · NO.04")
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
        .sensoryFeedback(.selection, trigger: selectedHeatmapDay)
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

    /// Editorial section opener: a large serif Chinese ordinal (壹/贰/叁/肆) in the
    /// theme's deep section accent, paired with a serif title and a tracked
    /// monospaced/rounded sub-label. The hairline rule on the right gives each
    /// section a "chapter break" silhouette, replacing the flat repeating 17pt
    /// semibold headers the old design used (which had no inter-section emphasis).
    @ViewBuilder
    private func sectionHeader(num: String, title: String, sub: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(num)
                .font(.literarySerif(size: 30))
                .foregroundStyle(palette.sectionAccent)
                .baselineOffset(-2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.literarySerif(size: 18, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                Text(sub)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(palette.secondaryText.opacity(0.75))
            }
            Spacer(minLength: 12)
            Rectangle()
                .fill(palette.sectionAccent.opacity(0.42))
                .frame(width: 28, height: 0.8)
                .padding(.bottom, 4)
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
        .padding(.horizontal, 2)
    }

    /// Variant A "editorial" hero: kicker → 60pt serif total figure → italic serif
    /// commentary → 印章 streak seal + inline goal progress. Drops the rounded
    /// system numerals + gradient card chrome the old hero used, in favor of one
    /// monumental serif figure that anchors the page typographically (the old
    /// 31pt rounded figure shared the same weight as section headers, so nothing
    /// dominated). Card chrome is replaced by a hairline rule under the hero.
    private var heroCard: some View {
        let streak = libraryStore.readingStats.currentStreak(calendar: calendar)
        let minutes = max(Int(totalDuration / 60), 0)
        let todaySeconds = libraryStore.readingStats.events
            .filter { calendar.isDateInToday($0.timestamp) }
            .reduce(0) { $0 + $1.durationSeconds }
        let todayMinutes = max(Int(todaySeconds / 60), 0)
        let hasGoal = dailyGoalMinutes > 0
        let dailyProgress = hasGoal ? min(Double(todayMinutes) / Double(dailyGoalMinutes), 1) : 0
        let goalReached = hasGoal && todayMinutes >= dailyGoalMinutes

        return VStack(alignment: .leading, spacing: 12) {
            // Kicker row — small accent label + hairline rule, no big icon chip.
            HStack(spacing: 8) {
                Text("阅读投入")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(palette.sectionAccent)
                Rectangle()
                    .fill(palette.sectionAccent.opacity(0.5))
                    .frame(width: 18, height: 1)
                Text("TOTAL TIME")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(palette.secondaryText.opacity(0.7))
                Spacer()
            }

            // The hero figure: a single serif glyph string. Set at 44pt rather
            // than the old 60pt — that size combined with literal spaces in the
            // duration string made the line read as four separate items instead
            // of one focal duration. 44pt still gives the page an unambiguous
            // headline since nothing else on the page approaches it.
            Text(formatDuration(totalDuration))
                .font(.literarySerif(size: 44, weight: .light))
                .tracking(-0.4)
                .foregroundStyle(palette.heroFigure)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.top, 2)

            // Kaiti SC sub-line — Chinese cursive script reads as a hand-set
            // editor's note rather than UI copy. `fixedSize` lets it wrap.
            literarySerifItalicText(heroSubtitle(minutes: minutes, streak: streak), size: 13)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // 印章 streak seal + goal section. The streak is rendered as a small
            // squared "seal" stamp in the section accent — visually a chop mark
            // pressed onto the page, not a candy capsule.
            HStack(alignment: .center, spacing: 10) {
                if streak > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("连读 \(streak) 天")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(0.4)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(palette.sectionAccent)
                    )
                    .shadow(color: palette.glow.opacity(0.22), radius: 6, x: 0, y: 2)
                }

                if hasGoal {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Menu {
                                dailyGoalMenuItems
                            } label: {
                                HStack(spacing: 4) {
                                    Text("今日 \(todayMinutes) / \(dailyGoalMinutes) 分钟")
                                        .font(.system(size: 12, weight: .semibold))
                                        .tracking(0.1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8.5, weight: .bold))
                                }
                                .foregroundStyle(palette.secondaryText)
                            }
                            Spacer(minLength: 6)
                            if goalReached {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("已达成")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(palette.sage)
                            }
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(palette.progressTrack)
                                Capsule()
                                    .fill(palette.readingTime)
                                    .frame(width: max(0, proxy.size.width * dailyProgress))
                                    .shadow(color: palette.glow.opacity(0.30), radius: 4, x: 0, y: 1)
                            }
                        }
                        .frame(height: 4)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Menu {
                        dailyGoalMenuItems
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "target")
                                .font(.system(size: 10, weight: .bold))
                            Text("设定今日目标")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .tracking(0.2)
                        }
                        .foregroundStyle(palette.readingTime)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(palette.readingTime.opacity(0.14)))
                        .overlay(Capsule().stroke(palette.readingTime.opacity(0.28), lineWidth: 0.7))
                    }
                    Spacer()
                }
            }
            .padding(.top, 4)

            // Bottom hairline rule — separates the hero block from the global
            // metric strip without the heavy card border the old design used.
            Rectangle()
                .fill(palette.divider.opacity(0.85))
                .frame(height: 0.6)
                .padding(.top, 6)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
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

    /// Sits directly under the hero hairline as a slim editorial stat strip:
    /// 读过/读完 and 翻页数 expressed as serif figures with a thin vertical rule
    /// between them. The old version was a chunky 3-column card that competed
    /// visually with the hero; 总时长 moved into the hero figure, leaving these
    /// two complementary totals that frame the journey at the top of the page.
    private var globalMetrics: some View {
        HStack(alignment: .top, spacing: 14) {
            EditorialFigure(
                kicker: "读过 · 读完",
                value: "\(readBookCount) / \(finishedBookCount)",
                unit: "本"
            )
            Rectangle()
                .fill(palette.divider.opacity(0.85))
                .frame(width: 0.6, height: 36)
                .padding(.top, 12)
            EditorialFigure(
                kicker: "翻页数",
                value: formatCount(totalPages),
                unit: "页"
            )
        }
        .padding(.horizontal, 2)
    }

    private var rangePicker: some View {
        Picker("时间范围", selection: $selectedRange) {
            ForEach(StatsRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Variant A period card: a 40pt serif figure dominates, with the report
    /// title as a small italic serif kicker line. Below it, an italic serif
    /// commentary line and a hairline-divided 3-column stat row (步调 / 字数 /
    /// 翻页). The 17pt header + chunky duration tag the old card used made
    /// every range card read identically — the serif figure here gives each
    /// 日/月/年 view a real editorial focal point.
    private var periodSummary: some View {
        // Earlier this card read `periodEvents` three times in a row, each
        // recomputing the full-events filter. Single-pass tally instead.
        let interval = selectedRange.interval(containing: Date(), calendar: calendar)
        var duration: TimeInterval = 0
        var pages = 0
        var characters = 0
        for event in libraryStore.readingStats.events where interval.contains(event.timestamp) {
            duration += event.durationSeconds
            pages += event.pageTurns
            characters += event.characterCount
        }
        let speed: Double = duration >= 60 ? Double(pages) / (duration / 60) : 0
        let hasPeriodData = duration > 0 || pages > 0 || characters > 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selectedRange.systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.sectionAccent)
                Text(selectedRange.reportTitle)
                    .font(.literarySerifItalic(size: 13))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            }

            // Songti period figure — the focal point. Falls back to "暂无" so the
            // 40pt slot stays at consistent height across day/month/year states.
            Text(hasPeriodData ? formatDuration(duration) : "暂无")
                .font(.literarySerif(size: 40, weight: .light))
                .foregroundStyle(hasPeriodData ? palette.heroFigure : palette.secondaryText.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            Text(hasPeriodData ? rangeCommentary(for: selectedRange) : emptyPeriodHint(for: selectedRange))
                .font(.literarySerifItalic(size: 12.5))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(palette.divider.opacity(0.85))
                .frame(height: 0.6)
                .padding(.top, 2)

            // Hairline 3-column strip — replaces the chunky pill row. The serif
            // figures + monospaced-tracked kicker labels give the card a printed
            // info-page feel rather than a dashboard chip cluster.
            HStack(alignment: .top, spacing: 12) {
                PeriodColumn(
                    kicker: "步调",
                    value: hasPeriodData && speed > 0 ? String(format: "%.1f", speed) : "—",
                    unit: hasPeriodData && speed > 0 ? "页/分" : nil,
                    accent: palette.inkBlue
                )
                Rectangle()
                    .fill(palette.divider.opacity(0.85))
                    .frame(width: 0.6, height: 28)
                PeriodColumn(
                    kicker: "字数",
                    value: hasPeriodData ? formatCount(characters) : "—",
                    unit: hasPeriodData ? "字" : nil,
                    accent: palette.clay
                )
                Rectangle()
                    .fill(palette.divider.opacity(0.85))
                    .frame(width: 0.6, height: 28)
                PeriodColumn(
                    kicker: "翻页",
                    value: hasPeriodData ? formatCount(pages) : "—",
                    unit: hasPeriodData ? "页" : nil,
                    accent: palette.sage
                )
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCard()
    }

    private func streakCalendarCard(buckets: [Date: DailyEventTotals]) -> some View {
        let monthStart = calendar.dateInterval(of: .month, for: displayedCalendarMonth)?.start ?? displayedCalendarMonth
        let summaries = monthlySummaries(containing: monthStart, buckets: buckets)
        let streak = libraryStore.readingStats.currentStreak(calendar: calendar)
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
        // Earlier this was `22 + rows * 43` which fit the raw content but left
        // no slack — on 6-row months TabView's page-style internal padding ate
        // into the top, clipping the first day row. The extra header allowance
        // + 1pt per row buys consistent breathing room for both 5- and 6-row
        // months without making 5-row months look stranded.
        let calendarHeight: CGFloat = 30 + CGFloat(weekRows) * 44

        return VStack(alignment: .leading, spacing: 14) {
            // Section title comes from the editorial sectionHeader above this card,
            // so the card opens directly with the 3 streak figures — same data,
            // but rendered as serif numerals with hairline rules so they read as
            // typeset headlines instead of pill chips.
            HStack(alignment: .top, spacing: 14) {
                CalendarFigure(kicker: "当前连续", value: "\(streak)", unit: "天", accent: palette.sectionAccent)
                Rectangle()
                    .fill(palette.divider.opacity(0.85))
                    .frame(width: 0.6, height: 36)
                    .padding(.top, 12)
                CalendarFigure(kicker: "最长连续", value: "\(longestStreak)", unit: "天", accent: palette.gold)
                Rectangle()
                    .fill(palette.divider.opacity(0.85))
                    .frame(width: 0.6, height: 36)
                    .padding(.top, 12)
                CalendarFigure(kicker: activeDaysLabel, value: "\(activeDays)", unit: "天", accent: palette.sage)
            }

            HStack(spacing: 8) {
                CalendarNavigationButton(systemName: "chevron.left.2") {
                    moveDisplayedCalendar(by: -1, component: .year)
                }

                CalendarNavigationButton(systemName: "chevron.left") {
                    moveDisplayedCalendar(by: -1, component: .month)
                }

                Text(monthTitle(monthStart))
                    .font(.literarySerif(size: 17))
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
                            summaries: monthlySummaries(containing: month, buckets: buckets),
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

    private func heatmapCard(buckets: [Date: DailyEventTotals]) -> some View {
        let summaries = weeklyHeatmapSummaries(buckets: buckets)
        let today = calendar.startOfDay(for: Date())
        let maxDuration = max(summaries.map(\.durationSeconds).max() ?? 1, 1)
        let selectedSummary = selectedHeatmapDay.flatMap { selectedDay in
            summaries.first { calendar.isDate($0.day, inSameDayAs: selectedDay) }
        }
        let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

        return VStack(alignment: .leading, spacing: 12) {
            // sectionHeader above provides the title; the card opens with an
            // italic serif kicker line describing the time window.
            literarySerifItalicText("记录近 12 周阅读状态", size: 12)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

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

    /// Variant A leaderboard: ranks rendered as large serif Roman numerals
    /// (I/II/III/IV/V) in the section accent (deep theme color) — replacing the
    /// circle-chip "1/2/3" the old version used, which competed with the book
    /// covers visually. Titles upgrade to serif, the rank-1 numeral gets the
    /// stronger section accent to mark it as the chapter lead.
    private var topBooksCard: some View {
        let interval = selectedTopBooksRange.interval(containing: Date(), calendar: calendar)
        let events = libraryStore.readingStats.events.filter { interval.contains($0.timestamp) }
        let books = topBooks(from: events)
        let romanRanks = ["I", "II", "III", "IV", "V"]

        return VStack(alignment: .leading, spacing: 14) {
            Text("按时长排序的阅读时光")
                .font(.literarySerifItalic(size: 12))
                .foregroundStyle(palette.secondaryText)

            StatsSegmentedControl(
                selection: $selectedTopBooksRange,
                options: TopBooksRange.allCases,
                title: \.title
            )

            if books.isEmpty {
                Text("\(selectedTopBooksRange.title)还没有可统计的阅读记录。")
                    .font(.literarySerifItalic(size: 13))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(books.prefix(5).enumerated()), id: \.element.id) { index, item in
                        let isLead = index == 0
                        let rankColor: Color = isLead ? palette.sectionAccent : palette.secondaryText.opacity(0.55)
                        HStack(alignment: .center, spacing: 14) {
                            Text(romanRanks[index])
                                .font(.literarySerif(size: 30))
                                .foregroundStyle(rankColor)
                                .frame(width: 34, alignment: .leading)

                            if let book = booksByID[item.id] {
                                StatsBookCover(book: book, width: 38, height: 54)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.title)
                                        .font(.literarySerif(size: 15, weight: .bold))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    if booksByID[item.id]?.isDeleted == true {
                                        RemovedFromLibraryBadge()
                                    }
                                }
                                Text("\(formatDuration(item.durationSeconds)) · \(formatCount(item.pageTurns)) 页 · \(formatCharacterCount(item.characterCount))")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)

                        if index < min(books.count, 5) - 1 {
                            Rectangle()
                                .fill(palette.divider.opacity(0.7))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
        }
        .padding(18)
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

    /// One-pass O(n) bucketing of all reading events by their startOfDay. Callers
    /// (heatmap / daily / monthly summaries) used to each filter the full event
    /// array per grid cell — 84 cells × thousands of events compounded to hundreds
    /// of thousands of comparisons per render and was the dominant cause of Stats
    /// tab lag on real devices. With this map, each cell lookup is O(1).
    private func bucketEventsByDay() -> [Date: DailyEventTotals] {
        var buckets: [Date: DailyEventTotals] = [:]
        for event in libraryStore.readingStats.events {
            let day = calendar.startOfDay(for: event.timestamp)
            var entry = buckets[day] ?? DailyEventTotals()
            entry.durationSeconds += event.durationSeconds
            entry.pageTurns += event.pageTurns
            entry.characterCount += event.characterCount
            buckets[day] = entry
        }
        return buckets
    }

    private func summary(for day: Date, in buckets: [Date: DailyEventTotals]) -> DailyReadingSummary {
        let entry = buckets[day] ?? DailyEventTotals()
        return DailyReadingSummary(
            day: day,
            durationSeconds: entry.durationSeconds,
            pageTurns: entry.pageTurns,
            characterCount: entry.characterCount,
            topBookID: nil
        )
    }

    private func weeklyHeatmapSummaries() -> [DailyReadingSummary] {
        weeklyHeatmapSummaries(buckets: bucketEventsByDay())
    }

    private func weeklyHeatmapSummaries(buckets: [Date: DailyEventTotals]) -> [DailyReadingSummary] {
        let today = calendar.startOfDay(for: Date())
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstColumnStart = calendar.date(byAdding: .day, value: -11 * 7, to: currentWeekStart) ?? today
        var summaries: [DailyReadingSummary] = []
        summaries.reserveCapacity(7 * 12)
        for weekday in 0..<7 {
            for week in 0..<12 {
                let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: firstColumnStart) ?? firstColumnStart
                summaries.append(summary(for: day, in: buckets))
            }
        }
        return summaries
    }

    private func dailySummaries(days count: Int) -> [DailyReadingSummary] {
        let today = calendar.startOfDay(for: Date())
        let buckets = bucketEventsByDay()
        return (0..<count).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return summary(for: day, in: buckets)
        }
    }

    private func monthlySummaries(containing date: Date) -> [DailyReadingSummary] {
        monthlySummaries(containing: date, buckets: bucketEventsByDay())
    }

    /// Variant that accepts a pre-computed day-bucket map so callers iterating
    /// over many months (the calendar TabView renders up to 24 pages at a time)
    /// don't redo the full-events scan per month — that was the dominant cause
    /// of laggy month swiping in Stats.
    private func monthlySummaries(containing date: Date, buckets: [Date: DailyEventTotals]) -> [DailyReadingSummary] {
        let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let daysToMonthEnd = calendar.dateComponents([.day], from: gridStart, to: monthEnd).day ?? 30
        let weeksNeeded = max(1, Int(ceil(Double(daysToMonthEnd) / 7.0)))
        let totalDays = weeksNeeded * 7
        return (0..<totalDays).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: gridStart) ?? gridStart
            return summary(for: day, in: buckets)
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

        // Compact CJK typography: no space between digits and units.
        // The hero figure renders at a smaller size now (44pt vs the
        // previous 60pt) — wide spacing on top of that read as 三件 separate
        // numbers rather than one duration.
        return remainder == 0 ? "\(hours)小时" : "\(hours)小时\(remainder)分"
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

private struct DailyReadingSummary: Identifiable {
    var id: Date { day }
    let day: Date
    let durationSeconds: TimeInterval
    let pageTurns: Int
    let characterCount: Int
    let topBookID: UUID?
}

/// Pre-aggregated daily totals built once per render from the events array, so
/// heatmap / calendar / weekly views can fetch a cell's data in O(1) instead of
/// re-filtering the entire events array per cell.
private struct DailyEventTotals {
    var durationSeconds: TimeInterval = 0
    var pageTurns: Int = 0
    var characterCount: Int = 0
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

/// Slim hairline-divided stat figure used under the hero and inside the period
/// card. Renders a tracked monospaced/rounded kicker (e.g. "翻页数"), a 22pt
/// serif value (the focal numeral), and an optional sub-unit ("页", "本").
/// Variant A's editorial substitute for the old chunky `StatMetricStrip` card.
private struct EditorialFigure: View {
    @Environment(\.statsPalette) private var palette
    let kicker: String
    let value: String
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(palette.secondaryText.opacity(0.85))
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.literarySerif(size: 24))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.secondaryText.opacity(0.85))
                        .baselineOffset(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Period-card stat column — same anatomy as EditorialFigure but the value
/// font is sized to fit three side-by-side columns inside a 16pt-padded card,
/// and the kicker color follows a per-column accent (步调/字数/翻页) so each
/// column carries its own quiet semantic tint without screaming.
private struct PeriodColumn: View {
    @Environment(\.statsPalette) private var palette
    let kicker: String
    let value: String
    var unit: String? = nil
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(accent.opacity(0.9))
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.literarySerif(size: 21))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryText.opacity(0.85))
                        .baselineOffset(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Calendar-card streak figure — sized between EditorialFigure (top of page)
/// and PeriodColumn (period card) since the calendar card lives further down
/// the page hierarchy. The accent param lets rank-1 ("当前连续") pull the
/// section accent while siblings stay in muted theme tints.
private struct CalendarFigure: View {
    @Environment(\.statsPalette) private var palette
    let kicker: String
    let value: String
    let unit: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(palette.secondaryText.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.literarySerif(size: 26))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.secondaryText.opacity(0.85))
                    .baselineOffset(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.literarySerif(size: 10, weight: .bold))
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
