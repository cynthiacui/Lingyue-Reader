import SwiftUI

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
        horizontalSizeClass == .compact ? 14 : 18
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

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
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.large)
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

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("阅读能量")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Text(formatDuration(totalDuration))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(heroSubtitle(minutes: minutes, streak: streak))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(0.16))
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.accent)
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
                            .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        if goalReached {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("已达成")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(theme.accent)
                        }
                    }
                    ProgressView(value: dailyProgress)
                        .tint(theme.accent)
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
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                }
            }
        }
        .padding(18)
        .background(theme.cardBackground.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 14, x: 0, y: 8)
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
                StatMetric(title: "总时长", value: formatMetricDuration(totalDuration), icon: "clock.fill"),
                StatMetric(title: "读过/读完", value: "\(readBookCount)本/\(finishedBookCount)本", icon: "books.vertical.fill"),
                StatMetric(title: "翻页数", value: formatCount(totalPages), icon: "arrow.turn.up.right")
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
        let insight = selectedRange == .month ? monthlyInsight() : ""

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(selectedRange.reportTitle, systemImage: selectedRange.systemImage)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(formatDuration(duration))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accent)
            }

            if hasPeriodData {
                HStack(spacing: 10) {
                    SmallStatPill(title: "效率", value: speed > 0 ? String(format: "%.1f 页/分", speed) : "—")
                    SmallStatPill(title: "字数", value: formatCharacterCount(characters))
                    SmallStatPill(title: "翻页", value: formatCount(pages))
                }
            }

            Text(selectedRange == .month ? insight : periodHint(duration: duration, pages: pages))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(3)
        }
        .padding(16)
        .background(theme.cardBackground.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var trendCard: some View {
        let points = trendPoints(for: selectedRange)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("趋势")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(selectedRange.trendExplanation)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
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
        .background(theme.cardBackground.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .foregroundStyle(theme.primaryText)
                Text("按月查看哪天读过")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
            }

            HStack(spacing: 10) {
                SmallStatPill(title: "当前连续", value: "\(streak) 天")
                SmallStatPill(title: "最长连续", value: "\(longestStreak) 天")
                SmallStatPill(title: activeDaysLabel, value: "\(activeDays) 天")
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
                    .foregroundStyle(theme.primaryText)
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
                    .fill(theme.accent)
                    .frame(width: 7, height: 7)
                Text("有颜色代表当天读过，描边为今天")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }
        }
        .padding(16)
        .background(theme.cardBackground.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    .foregroundStyle(theme.primaryText)
                Text("近 12 周每天读多久，颜色越深越久")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
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
                                .foregroundStyle(theme.secondaryText)
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
                                    Button {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                            selectedHeatmapDay = isSelected ? nil : summary.day
                                        }
                                    } label: {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(isFuture ? Color.clear : heatColor(summary.durationSeconds, maxDuration: maxDuration))
                                            .aspectRatio(1, contentMode: .fit)
                                            .frame(maxWidth: .infinity)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                    .stroke(isSelected ? theme.accent : .clear, lineWidth: 2)
                                            )
                                            .shadow(color: isSelected ? theme.accent.opacity(0.18) : .clear, radius: 5, x: 0, y: 2)
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

                HStack(spacing: 6) {
                    Text("少")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(heatColor(index == 0 ? 0 : maxDuration * Double(index) / 4, maxDuration: maxDuration))
                            .frame(width: 16, height: 8)
                    }
                    Text("多")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                }

                if let selectedSummary {
                    StatsSelectionPill(
                        icon: "calendar",
                        title: dayTitle(selectedSummary.day),
                        value: formatDuration(selectedSummary.durationSeconds),
                        detail: "\(formatCount(selectedSummary.pageTurns)) 页 · \(formatCharacterCount(selectedSummary.characterCount))"
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                Text("近 12 周还没有阅读记录。开始阅读后，这里会显示你的节奏。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(theme.cardBackground.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: selectedHeatmapDay)
    }

    private var topBooksCard: some View {
        let interval = selectedTopBooksRange.interval(containing: Date(), calendar: calendar)
        let events = libraryStore.readingStats.events.filter { interval.contains($0.timestamp) }
        let books = topBooks(from: events)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("TOP 书")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("按阅读时长排行")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }

            Picker("TOP 书范围", selection: $selectedTopBooksRange) {
                ForEach(TopBooksRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)

            if books.isEmpty {
                Text("\(selectedTopBooksRange.title)还没有可统计的阅读记录。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(Array(books.prefix(5).enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.accent)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(theme.accent.opacity(0.12)))

                        if let book = booksByID[item.id] {
                            StatsBookCover(book: book, width: 38, height: 54)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.primaryText)
                                    .lineLimit(1)
                                if booksByID[item.id]?.isDeleted == true {
                                    Text("已移出书架")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(theme.secondaryText)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(theme.subtleCardBackground))
                                }
                            }
                            Text("\(formatDuration(item.durationSeconds)) · \(formatCount(item.pageTurns)) 页 · \(formatCharacterCount(item.characterCount))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(16)
        .background(theme.cardBackground.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    private func periodHint(duration: TimeInterval, pages: Int) -> String {
        if duration <= 0 {
            switch selectedRange {
            case .day: return "今天还没开读。翻几页后，这里会热闹起来。"
            case .month: return "本月还没读，先选一本翻几页吧。"
            case .year: return "今年还没读，先选一本开个头吧。"
            }
        }
        let minutes = max(duration / 60, 1)
        return "这段时间平均每分钟翻 \(String(format: "%.1f", Double(pages) / minutes)) 页，节奏还挺有数。"
    }

    private func weeksInMonth(containing date: Date) -> Int {
        let monthStart = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let daysToMonthEnd = calendar.dateComponents([.day], from: gridStart, to: monthEnd).day ?? 30
        return max(1, Int(ceil(Double(daysToMonthEnd) / 7.0)))
    }

    private func monthlyInsight() -> String {
        let interval = StatsRange.month.interval(containing: Date(), calendar: calendar)
        let monthEvents = libraryStore.readingStats.events.filter { interval.contains($0.timestamp) }
        guard !monthEvents.isEmpty else {
            return "本月还没留下阅读波纹，打开一本书就有了。"
        }
        let midDay = calendar.date(byAdding: .day, value: 15, to: interval.start) ?? interval.start
        let firstHalf = monthEvents.filter { $0.timestamp < midDay }.reduce(0) { $0 + $1.durationSeconds }
        let secondHalf = monthEvents.filter { $0.timestamp >= midDay }.reduce(0) { $0 + $1.durationSeconds }
        if secondHalf > firstHalf * 1.15 {
            return "本月后半段明显读得更勤了，手感回来了。"
        }
        if firstHalf > secondHalf * 1.15 {
            return "本月前半段更稳，后半段可以随手续一点。"
        }
        return "本月读得挺均匀，照这个节奏就很好。"
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

    private func heatColor(_ duration: TimeInterval, maxDuration: TimeInterval) -> Color {
        guard duration > 0 else { return theme.secondaryText.opacity(0.10) }
        let intensity = min(max(duration / maxDuration, 0.18), 1)
        return theme.accent.opacity(0.18 + intensity * 0.72)
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
        case .day: return "今日报告"
        case .month: return "本月报告"
        case .year: return "年度报告"
        }
    }

    var trendExplanation: String {
        switch self {
        case .day: return "今天每个时段读了多久"
        case .month: return "本月每天读了多久"
        case .year: return "今年每个月读了多久"
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
}

private struct StatMetricStrip: View {
    @Environment(\.appTheme) private var theme
    let metrics: [StatMetric]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                StatMetricColumn(metric: metric)
                    .frame(maxWidth: .infinity)

                if index < metrics.count - 1 {
                    Rectangle()
                        .fill(theme.secondaryText.opacity(0.12))
                        .frame(width: 1, height: 52)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(theme.cardBackground.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatMetricColumn: View {
    @Environment(\.appTheme) private var theme
    let metric: StatMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: metric.icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.accent.opacity(0.13)))

                Text(metric.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Text(metric.value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmallStatPill: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.subtleCardBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatsTrendChart: View {
    @Environment(\.appTheme) private var theme
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
                    Rectangle()
                        .fill(theme.secondaryText.opacity(0.12))
                        .frame(height: 1)
                        .position(x: width / 2, y: axisY)

                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        if !point.label.isEmpty {
                            let x = xPosition(for: index, width: width)
                            Text(point.label)
                                .font(.system(size: 10, weight: selectedPointID == point.id ? .bold : .semibold, design: .rounded))
                                .foregroundStyle(selectedPointID == point.id ? theme.accent : theme.secondaryText)
                                .frame(width: 46)
                                .position(x: clamped(x, minimum: 23, maximum: width - 23), y: axisY + 15)
                        }
                    }
                }

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    if hasReadingData && point.durationSeconds > 0 {
                        let x = xPosition(for: index, width: width)
                        let height = barHeight(for: point.durationSeconds, maxValue: maxValue)
                        let isSelected = selectedPointID == point.id

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                selectedPointID = point.id
                            }
                        } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            theme.accent.opacity(isSelected ? 1 : 0.92),
                                            theme.accent.opacity(isSelected ? 0.48 : 0.30)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: barWidth, height: height)
                                .shadow(color: isSelected ? theme.accent.opacity(0.24) : .clear, radius: 5, x: 0, y: 2)
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
                   selected.durationSeconds > 0 {
                    let x = xPosition(for: index, width: width)
                    let height = barHeight(for: selected.durationSeconds, maxValue: maxValue)
                    Text(compactDuration(selected.durationSeconds))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.cardBackground.opacity(0.96)))
                        .shadow(color: theme.cardShadow.opacity(0.65), radius: 5, x: 0, y: 2)
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
        if points.count <= 12 { return 14 }
        if points.count <= 24 { return 9 }
        return 5
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
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(theme.accent.opacity(0.13)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.subtleCardBackground.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CalendarNavigationButton: View {
    @Environment(\.appTheme) private var theme
    let systemName: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isEnabled ? theme.primaryText : theme.secondaryText.opacity(0.4))
                .frame(width: 34, height: 30)
                .background(theme.subtleCardBackground.opacity(isEnabled ? 0.76 : 0.34))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct StatsMonthlyReadingCalendar: View {
    @Environment(\.appTheme) private var theme
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
                        .foregroundStyle(theme.secondaryText)
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
    @Environment(\.appTheme) private var theme
    let summary: DailyReadingSummary
    let isCurrentMonth: Bool
    private let calendar = Calendar.current

    var body: some View {
        let hasRead = summary.durationSeconds > 0

        VStack(spacing: 3) {
            Text("\(calendar.component(.day, from: summary.day))")
                .font(.system(size: 11, weight: hasRead ? .bold : .semibold, design: .rounded))
                .foregroundStyle(textColor(hasRead: hasRead))

            Capsule()
                .fill(hasRead && isCurrentMonth ? theme.accent.opacity(0.78) : .clear)
                .frame(width: 14, height: 3)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor(hasRead: hasRead))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .opacity(isCurrentMonth ? 1 : 0.34)
    }

    private func backgroundColor(hasRead: Bool) -> Color {
        guard isCurrentMonth else {
            return theme.subtleCardBackground.opacity(0.26)
        }
        if hasRead {
            return theme.accent.opacity(0.70)
        }
        return theme.subtleCardBackground.opacity(0.50)
    }

    private func textColor(hasRead: Bool) -> Color {
        guard isCurrentMonth else {
            return theme.secondaryText.opacity(0.58)
        }
        if hasRead {
            return theme.primaryText
        }
        return theme.secondaryText.opacity(0.72)
    }

    private var borderColor: Color {
        if calendar.isDateInToday(summary.day) {
            return theme.accent
        }
        return .clear
    }

    private var borderWidth: CGFloat {
        calendar.isDateInToday(summary.day) ? 1.5 : 0
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
