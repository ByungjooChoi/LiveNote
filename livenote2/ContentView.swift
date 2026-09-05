import SwiftUI
import Translation

// MARK: - 테마 (한지 · 쪽빛 · 먹 — 앱 아이콘과 동일 계열)

enum Theme {
    static let canvas = Color(red: 0.972, green: 0.965, blue: 0.945)       // 한지
    static let card = Color.white
    static let cardStroke = Color.black.opacity(0.07)
    static let sidebarTop = Color(red: 0.145, green: 0.170, blue: 0.260)   // 먹남
    static let sidebarBottom = Color(red: 0.085, green: 0.100, blue: 0.165)
    static let accent = Color(red: 0.153, green: 0.298, blue: 0.612)       // 쪽빛
    static let vermilion = Color(red: 0.769, green: 0.224, blue: 0.180)    // 주홍
}

extension View {
    /// 흰 카드 스타일 (라운드 + 얇은 테두리)
    func themedCard() -> some View {
        background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
    }
}

// MARK: - 루트: 좌측 레일 + 메인 콘텐츠

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var screen: Screen = .home

    enum Screen: Equatable {
        case home
        case chat
        case tasks
        case live
        case meeting(URL)
        case settings
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail(screen: $screen)
            content
        }
        .frame(minWidth: 840, minHeight: 520)
        .background(Theme.canvas)
        .preferredColorScheme(.light)
        // Apple Translation 세션은 이 modifier를 통해서만 열립니다 (EN→KO 온디바이스)
        .translationTask(app.translator.config) { session in
            await app.translator.serve(session: session, state: app)
        }
        .sheet(isPresented: Binding(
            get: { app.showGeminiKeyPrompt },
            set: { app.showGeminiKeyPrompt = $0 }
        )) {
            GeminiKeySheet(
                errorText: app.geminiKeychainError,
                canRemove: app.hasGeminiKey || app.geminiKeychainError != nil,
                onSave: { app.saveGeminiKey($0) },
                onRemove: {
                    app.removeGeminiKey()
                },
                onCancel: {
                    // 오류는 load/save/remove 성공 시에만 지운다 (Settings에서 계속 보여야 함)
                    app.showGeminiKeyPrompt = false
                }
            )
        }
        .onChange(of: app.isRunning) { _, running in
            if running { screen = .live }
        }
        // 창 밖(알림 팝업 등)에서 온 화면 전환 요청 반영
        .onChange(of: app.pendingScreen) { _, _ in
            consumePendingScreen()
        }
        // 창이 닫혀 있는 동안 들어온 요청은 창이 다시 열릴 때 여기서 소비한다.
        .onAppear {
            consumePendingScreen()
        }
    }

    private func consumePendingScreen() {
        guard let pending = app.pendingScreen else { return }
        switch pending {
        case .settings: screen = .settings
        case .chat: screen = .chat
        case .tasks: screen = .tasks
        }
        app.pendingScreen = nil
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .home:
            HomeView(screen: $screen)
        case .chat:
            ChatFullView()
        case .tasks:
            TasksView(screen: $screen)
        case .live:
            LiveMeetingView()
        case .meeting(let url):
            MeetingDetailView(url: url, screen: $screen)
                .id(url)
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - 좌측 레일 (Granola식 미니 메뉴)

struct SidebarRail: View {
    @Environment(AppState.self) private var app
    @Binding var screen: ContentView.Screen

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("LiveNote")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 16)

            railItem("Home", icon: "house.fill", target: .home,
                     selected: isHome)
            railItem("Chat", icon: "bubble.left.and.bubble.right.fill", target: .chat,
                     selected: screen == .chat)
            railItem("Tasks", icon: "checklist", target: .tasks,
                     selected: screen == .tasks)
            if app.isRunning || !app.rows.isEmpty {
                railItem(app.isRunning ? "Live · Listening" : "Live",
                         icon: "waveform", target: .live,
                         selected: screen == .live,
                         dot: app.isRunning ? Theme.vermilion : nil)
            }

            Spacer()

            if app.isRunning {
                HStack(spacing: 6) {
                    Circle().fill(Theme.vermilion).frame(width: 7, height: 7)
                    Text("Recording")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.leading, 10)
                .padding(.bottom, 6)
            }

            railItem("Settings", icon: "gearshape.fill", target: .settings,
                     selected: screen == .settings)
        }
        .padding(14)
        .frame(width: 180, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(colors: [Theme.sidebarTop, Theme.sidebarBottom],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var isHome: Bool {
        if case .meeting = screen { return true }   // 상세는 홈 계열로 하이라이트
        return screen == .home
    }

    private func railItem(_ title: String, icon: String, target: ContentView.Screen,
                          selected: Bool, dot: Color? = nil) -> some View {
        Button {
            screen = target
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                Spacer()
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(.white.opacity(selected ? 1.0 : 0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.white.opacity(0.14) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 홈 (Granola식: Coming up 상단 + 전체 회의 피드)

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Binding var screen: ContentView.Screen
    @State private var ask = ""

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let sectionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d (EEE)"
        return formatter
    }()

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Coming up")
                        .font(.system(size: 27, weight: .semibold, design: .serif))
                    comingUpCard

                    Text("Meetings")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 6)
                    meetingFeed
                }
                .padding(28)
                .padding(.bottom, 84)   // 하단 ask 바에 가리지 않도록
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            askBar
        }
    }

    // MARK: 하단 ask 바 — Chat 화면과 같은 대화 상태를 공유 (진입 경로만 다름)

    private var askBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
            TextField("Ask across all your meetings…", text: $ask)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit(submitAsk)
            ChatModelMenu()
            Button("Ask", action: submitAsk)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .themedCard()
        .frame(maxWidth: 600)
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .padding(.bottom, 22)
    }

    private func submitAsk() {
        let question = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        ask = ""
        app.startNewChat()
        screen = .chat
        app.askChat(question, scope: .archive)
    }

    // MARK: Coming up 카드

    private var comingUpCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.isRunning {
                HStack(spacing: 10) {
                    Circle().fill(Theme.vermilion).frame(width: 9, height: 9)
                    Text("Listening — \(app.rows.count) segments")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Open") { screen = .live }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                }
                .padding(14)
                Divider().padding(.horizontal, 14)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(Theme.vermilion)
                    Text("New recording")
                        .font(.callout.weight(.medium))
                    Spacer()
                    StartMenu { mode in
                        app.start(mode: mode)
                        screen = .live
                    }
                }
                .padding(14)
                if !app.calendar.todayUpcoming.isEmpty {
                    Divider().padding(.horizontal, 14)
                }
            }

            ForEach(app.calendar.todayUpcoming.prefix(6)) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.isNow() ? Theme.vermilion : Theme.accent.opacity(0.6))
                            .frame(width: 4, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text("\(Self.timeFormatter.string(from: item.start)) ~ \(Self.timeFormatter.string(from: item.end))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        let openTaskCount = app.tasks.openCount(forAttendeeNames: item.attendees.map(\.name))
                        if openTaskCount > 0 {
                            Text("\(openTaskCount) open")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        BriefRowAccessory(
                            status: app.briefing.status(for: item),
                            onRefresh: {
                                Task {
                                    await app.briefing.ensureBrief(for: item, force: true)
                                }
                            }
                        )
                        Spacer()
                        if item.isNow(), !app.isRunning {
                            Button("Start now") {
                                app.startUpcomingMeeting(link: item.deepLink ?? item.webLink)
                                screen = .live
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.vermilion)
                            .controlSize(.small)
                        }
                    }
                    if case .ready(let brief) = app.briefing.status(for: item) {
                        BriefDisclosure(brief: brief)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            if app.calendar.todayUpcoming.isEmpty && !app.isRunning {
                Text("No more events today")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(14)
            } else {
                Spacer().frame(height: 8)
            }
        }
        .themedCard()
    }

    // MARK: 회의 피드

    private struct DaySection: Identifiable {
        let id: Date
        let label: String
        let meetings: [MeetingSummary]
    }

    private var daySections: [DaySection] {
        let calendar = Foundation.Calendar.current
        let grouped = Dictionary(grouping: app.meetingStore.meetings) {
            calendar.startOfDay(for: $0.startedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            let label: String
            if calendar.isDateInToday(day) {
                label = "Today"
            } else if calendar.isDateInYesterday(day) {
                label = "Yesterday"
            } else {
                label = Self.sectionFormatter.string(from: day)
            }
            return DaySection(
                id: day,
                label: label,
                meetings: (grouped[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            )
        }
    }

    /// 전체 회의 피드 (날짜 섹션별)
    @ViewBuilder
    private var meetingFeed: some View {
        if app.meetingStore.meetings.isEmpty {
            Text("No meetings yet. Start your first recording.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 20)
        }
        ForEach(daySections) { section in
            VStack(alignment: .leading, spacing: 8) {
                Text(section.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(section.meetings) { meeting in
                    meetingCard(meeting)
                }
            }
        }
    }

    private func meetingCard(_ meeting: MeetingSummary) -> some View {
        Button {
            screen = .meeting(meeting.url)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Text(String(meeting.title.prefix(1)))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(meeting.dateLabel) · \(meeting.rowCount)건 · \(meeting.durationLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .themedCard()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
            }
            Button("Delete", role: .destructive) {
                app.meetingStore.delete(meeting)
            }
        }
    }
}

// MARK: - 회의 상세 (요약 중심 + 하단 채팅)

struct MeetingDetailView: View {
    @Environment(AppState.self) private var app
    let url: URL
    @Binding var screen: ContentView.Screen
    @State private var meeting: SavedMeeting?
    @State private var showTranscript = false
    @State private var selectedRecipe: Recipe?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let meeting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(meeting.title ?? MeetingStore.resolveTitleFallback(meeting))
                            .font(.system(size: 24, weight: .bold, design: .serif))
                        metaLine(meeting)

                        if app.summaryPhase == .generating {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Generating minutes…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themedCard()
                        } else if let summary = meeting.summary {
                            SummaryRenderView(markdown: summary)
                                .padding(18)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .themedCard()

                            ActionItemsCard(meetingURL: url)
                        } else {
                            VStack(spacing: 10) {
                                Text("No minutes yet")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Button("Generate minutes") { app.generateSummary(for: url) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.accent)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity)
                            .themedCard()
                        }

                        if case .failed(let message) = app.summaryPhase {
                            Text("Minutes failed: \(message)")
                                .font(.caption)
                                .foregroundStyle(Theme.vermilion)
                                .textSelection(.enabled)
                        }

                        if showTranscript {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(meeting.rows) { row in
                                    transcriptRow(row, meeting: meeting)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themedCard()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("회의를 불러올 수 없습니다", systemImage: "exclamationmark.folder")
                    .frame(maxHeight: .infinity)
            }
            Divider()
            ChatPanel(scope: .saved(url))
        }
        .onAppear { meeting = app.meetingStore.load(url) }
        .onChange(of: app.summaryPhase) { _, newPhase in
            if newPhase == .idle { meeting = app.meetingStore.load(url) }
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeRunSheet(recipe: recipe, currentMeeting: url)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                screen = .home
            } label: {
                Label("Home", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            Spacer()
            let meetingRecipes = app.recipeStore.recipes.filter { $0.scopeDefault == .currentMeeting }
            if !meetingRecipes.isEmpty {
                Menu {
                    ForEach(meetingRecipes) { recipe in
                        Button {
                            selectedRecipe = recipe
                        } label: {
                            Label(recipe.title, systemImage: recipe.icon.isEmpty ? Recipe.defaultIcon : recipe.icon)
                        }
                    }
                } label: {
                    Label("Recipes", systemImage: "sparkles")
                        .font(.caption)
                }
            }
            Toggle("Show transcript", isOn: $showTranscript)
                .toggleStyle(.checkbox)
                .font(.caption)
            Button {
                app.generateSummary(for: url)
            } label: {
                Label("Regenerate minutes", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .disabled(app.summaryPhase == .generating)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Finder", systemImage: "folder")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metaLine(_ meeting: SavedMeeting) -> some View {
        let total = Int(meeting.durationSeconds)
        let duration = total >= 60 ? "\(total / 60)m" : "\(total)s"
        let names = Set(meeting.rows.map {
            MeetingStore.resolveName(row: $0, myName: meeting.myName, speakerNames: meeting.speakerNames)
        })
        return Text("\(MeetingStore.longDateLabel(meeting.startedAt)) · \(duration) · \(names.count) participants · \(meeting.rows.count) segments")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func transcriptRow(_ row: TranscriptRow, meeting: SavedMeeting) -> some View {
        let name = MeetingStore.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
        let color = LiveMeetingView.chipColor(channel: row.channel, slot: row.speakerSlot, name: row.speakerName)
        return HStack(alignment: .top, spacing: 10) {
            SpeakerChipLabel(name: name, color: color)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.english)
                    .font(.callout)
                    .textSelection(.enabled)
                if let korean = row.korean {
                    Text(korean)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Text(row.timeLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

// MARK: - 요약 마크다운 렌더러 (경량)

struct SummaryRenderView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                render(line)
            }
        }
    }

    @ViewBuilder
    private func render(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("# ") {
            Text(String(trimmed.dropFirst(2)))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 10)
        } else if trimmed.hasPrefix("## ") {
            Text(String(trimmed.dropFirst(3)))
                .font(.headline)
                .padding(.top, 6)
        } else if trimmed.hasPrefix("- ") {
            let indentLevel = (line.prefix(while: { $0 == " " }).count) / 2
            HStack(alignment: .top, spacing: 6) {
                Text(indentLevel > 0 ? "◦" : "•")
                    .foregroundStyle(indentLevel > 0 ? .secondary : Color.primary)
                inline(String(trimmed.dropFirst(2)))
            }
            .padding(.leading, CGFloat(indentLevel) * 16)
        } else {
            inline(trimmed)
        }
    }

    private func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 채팅 전용 화면 (레일의 "채팅" — 전체 아카이브 대상)

struct ChatFullView: View {
    @Environment(AppState.self) private var app
    @State private var ask = ""
    @State private var showAllChats = false
    @State private var selectedRecipe: Recipe?

    var body: some View {
        Group {
            if app.chatMessages.isEmpty {
                chatHome
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            app.startNewChat()
                        } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                    .background(Theme.canvas)
                    ChatPanel(scope: .archive, expanded: true)
                }
            }
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeRunSheet(recipe: recipe, currentMeeting: nil)
        }
    }

    // MARK: 채팅 홈 (Granola식: 중앙 위 히어로 + 최근 대화 목록)

    private var chatHome: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(greeting)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .padding(.top, 64)

                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.accent)
                    TextField("Ask across all your meetings…", text: $ask)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .onSubmit(submitAsk)
                    ChatModelMenu()
                    Button("Ask", action: submitAsk)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                        .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .themedCard()
                .frame(maxWidth: 600)

                RecipesRow(
                    onSelect: { recipe in
                        selectedRecipe = recipe
                    },
                    onSeeAll: {
                        app.pendingScreen = .settings
                    }
                )
                .frame(maxWidth: 600)

                recentChats
                    .frame(maxWidth: 600)
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .background(Theme.canvas)
    }

    private var visibleChats: [SavedChat] {
        showAllChats ? app.chatStore.chats : Array(app.chatStore.chats.prefix(3))
    }

    private var recentChats: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recents")
                    .font(.title3.weight(.semibold))
                Spacer()
                if app.chatStore.chats.count > 3 {
                    Button(showAllChats ? "Show less" : "See all") {
                        withAnimation(.easeInOut(duration: 0.15)) { showAllChats.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
                }
            }
            if app.chatStore.chats.isEmpty {
                Text("No conversations yet. Ask your first question above.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 12)
            }
            ForEach(visibleChats) { chat in
                Button {
                    app.openChat(chat)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(Theme.accent.opacity(0.7))
                        Text(chat.title)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(chat.ageLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .themedCard()
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        app.chatStore.delete(chat)
                    }
                }
            }
        }
    }

    private var greeting: String {
        let first = app.myName.split(separator: " ").first.map(String.init) ?? ""
        if first.isEmpty || first == "Me" { return "Ask anything" }
        return "Hi \(first), ask anything"
    }

    private func submitAsk() {
        let question = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        ask = ""
        app.startNewChat()
        app.askChat(question, scope: .archive)
    }
}

// MARK: - 라이브 회의 뷰

struct LiveMeetingView: View {
    @Environment(AppState.self) private var app
    @State private var editingRowID: UUID?
    @State private var draftName: String = ""

    static let slotColors: [Color] = [
        .green, .orange, .purple, .pink, .teal, .indigo, .mint, .brown,
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            banners
            if let brief = app.briefing.currentBrief {
                LiveBriefPanel(brief: brief, lastError: app.briefing.lastError)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            summarySection
            transcript
            Divider()
            ChatPanel(scope: (app.isRunning || !app.rows.isEmpty) ? .live : .archive)
        }
    }

    // MARK: 요약 (중지 후 표시)

    @ViewBuilder
    private var summarySection: some View {
        if !app.isRunning, !app.rows.isEmpty {
            SummaryCard(
                summary: app.currentSummary,
                phase: app.summaryPhase,
                onGenerate: { app.generateSummaryForCurrentSession() }
            )
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    // MARK: 헤더

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if app.currentStartMode == .inPerson, app.isActive || !app.rows.isEmpty {
                ModeBadge(text: "In person", systemImage: "person.2.fill")
                    .help("In-person mode: microphone only, speakers separated into slots.")
            }

            Spacer()

            if app.isRunning {
                HStack(spacing: 4) {
                    Button {
                        app.setMicMuted(!app.micMuted)
                    } label: {
                        Label(app.micMuted ? "Muted" : "Mic",
                              systemImage: app.micMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.caption)
                            .foregroundStyle(app.micMuted ? Theme.vermilion : .green)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help(app.micMuted
                          ? "Mic muted — your voice and speaker echo are not transcribed. Click to unmute (⌘⇧M)"
                          : "Click to mute the mic (⌘⇧M). Syncs with Zoom mute automatically.")
                    ProgressView(value: Double(min(1.0, app.micLevel)))
                        .progressViewStyle(.linear)
                        .frame(width: 48)
                        .tint(app.micMuted ? Theme.vermilion : (app.micLevel > 0.05 ? .green : .gray))
                }
                Label("System audio", systemImage: app.systemAudioAvailable ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(app.systemAudioAvailable ? .green : .orange)
            }

            if app.backend == .cloud, app.translationEnabled, app.isRunning, let status = app.cloudStatus {
                Circle()
                    .fill(status == .connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .help(status == .connected
                          ? "Cloud translation connected"
                          : "Cloud translation connecting or reconnecting — log: ~/Documents/LiveNote/logs/cloud.log")
            }

            if !app.isRunning, let savedURL = app.currentMeetingURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                } label: {
                    Label("Saved", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }

            Button(action: toggle) {
                Text(buttonTitle)
                    .frame(minWidth: 72)
            }
            .keyboardShortcut("r", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(app.isRunning ? Theme.vermilion : Theme.accent)
            .disabled(isPreparing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 안내 배너

    @ViewBuilder
    private var banners: some View {
        if let notice = app.noticeMessage {
            BannerView(text: notice, color: .blue, icon: "info.circle.fill")
        }
        if case .error(let message) = app.phase {
            BannerView(text: message, color: .red)
        }
        if let systemMessage = app.systemAudioMessage {
            BannerView(text: systemMessage, color: .orange)
        }
        if let diarizerIssue = app.diarizerMessage {
            BannerView(text: diarizerIssue, color: .orange)
        }
        if let translationIssue = app.translator.issueMessage {
            BannerView(text: translationIssue, color: .orange)
        }
        if let cloudIssue = app.cloudTranslationMessage {
            BannerView(text: cloudIssue, color: .orange)
        }
        if let zoomTagIssue = app.zoomTagMessage {
            BannerView(
                text: zoomTagIssue,
                color: .orange,
                actionTitle: "Open Accessibility Settings",
                action: {
                    NSWorkspace.shared.open(ZoomSpeakerTagger.accessibilitySettingsURL)
                }
            )
        }
    }

    // MARK: 전사 목록

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if app.rows.isEmpty && !hasVolatile {
                        emptyPlaceholder
                    }
                    ForEach(app.rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                    volatileViews
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(16)
            }
            .onChange(of: app.rows.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
            .onChange(of: app.volatileText) {
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        }
    }

    private func rowView(_ row: TranscriptRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            speakerChip(for: row)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.english)
                    .font(.body)
                    .textSelection(.enabled)
                if let korean = row.korean {
                    Text(korean)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if translationPending {
                    Text("Translating…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(row.timeLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    // MARK: 화자 칩

    @ViewBuilder
    private func speakerChip(for row: TranscriptRow) -> some View {
        let name = app.displayName(for: row)
        let color = Self.chipColor(channel: row.channel, slot: row.speakerSlot, name: row.speakerName)
        if row.speakerName != nil {
            SpeakerChipLabel(name: name, color: color)
                .help("Auto-recognized from Zoom")
        } else {
            Button {
                draftName = name
                editingRowID = row.id
            } label: {
                SpeakerChipLabel(name: name, color: color)
            }
            .buttonStyle(.plain)
            .help("Click to rename speaker")
            .popover(isPresented: Binding(
                get: { editingRowID == row.id },
                set: { if !$0 { editingRowID = nil } }
            )) {
                renamePopover(for: row)
            }
        }
    }

    private func renamePopover(for row: TranscriptRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.channel == .me ? "My name" : "Speaker name")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commitRename(for: row) }

            if row.channel == .them, !app.attendeeCandidates.isEmpty {
                Divider()
                Text("Calendar attendees")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(app.attendeeCandidates.prefix(8), id: \.self) { candidate in
                    Button {
                        draftName = candidate
                        commitRename(for: row)
                    } label: {
                        Label(candidate, systemImage: "person.crop.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }

            HStack {
                Spacer()
                Button("Save") { commitRename(for: row) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func commitRename(for row: TranscriptRow) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            switch row.channel {
            case .me:
                app.renameMe(to: name)
            case .them:
                if let slot = row.speakerSlot {
                    app.renameSpeaker(slot: slot, to: name)
                }
            }
        }
        editingRowID = nil
    }

    static func chipColor(channel: AudioChannel, slot: Int?, name: String? = nil) -> Color {
        switch channel {
        case .me:
            return .blue
        case .them:
            if let name, !name.isEmpty {
                return slotColors[Self.stableHash(name) % slotColors.count]
            }
            guard let slot else { return Color.primary.opacity(0.55) }
            return slotColors[slot % slotColors.count]
        }
    }

    private static func stableHash(_ text: String) -> Int {
        var hash: UInt32 = 5381
        for scalar in text.unicodeScalars {
            hash = hash &* 33 &+ scalar.value
        }
        return Int(hash % 1_000_000)
    }

    // MARK: 잠정(volatile) 행

    @ViewBuilder
    private var volatileViews: some View {
        ForEach([AudioChannel.me, .them], id: \.self) { channel in
            if let text = app.volatileText[channel], !text.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text(app.volatileName(for: channel))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((channel == .me ? Color.blue : Color.gray).opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                        .frame(minWidth: 64, alignment: .leading)
                    Text(text + " …")
                        .font(.body)
                        .italic()
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent.opacity(0.5))
            Text("Press Start to transcribe English speech and translate to Korean.\nSpeaker names are tagged automatically in Zoom meetings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    // MARK: 헬퍼

    private var translationPending: Bool {
        guard app.translationEnabled else { return false }
        switch app.backend {
        case .local:
            return app.translator.config != nil && app.translator.issueMessage == nil
        case .cloud:
            return app.cloudTranslationMessage == nil
        }
    }

    private var hasVolatile: Bool {
        app.volatileText.values.contains { !$0.isEmpty }
    }

    private var isPreparing: Bool {
        if case .preparing = app.phase { return true }
        return false
    }

    private var statusColor: Color {
        switch app.phase {
        case .idle: return .gray
        case .preparing: return .orange
        case .listening: return .green
        case .error: return Theme.vermilion
        }
    }

    private var statusText: String {
        switch app.phase {
        case .idle:
            return app.rows.isEmpty ? "Idle" : "Stopped — \(app.rows.count) segments"
        case .preparing(let message):
            return message
        case .listening:
            return "Listening"
        case .error:
            return "Error"
        }
    }

    private var buttonTitle: String {
        app.isRunning ? "Stop" : "Start"
    }

    private func toggle() {
        if app.isRunning {
            app.stop()
        } else {
            app.start()
        }
    }
}

// MARK: - 요약 카드 (라이브 뷰 중지 직후용)

struct SummaryCard: View {
    let summary: String?
    let phase: AppState.SummaryPhase
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Minutes", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                Spacer()
                if phase == .generating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(summary == nil ? "Generate" : "Regenerate", action: onGenerate)
                        .controlSize(.small)
                }
            }
            if case .failed(let message) = phase {
                Text("Minutes failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(Theme.vermilion)
                    .textSelection(.enabled)
            }
            if let summary {
                Divider()
                SummaryRenderView(markdown: summary)
            }
        }
        .padding(14)
        .themedCard()
    }
}

// MARK: - AI 채팅 모델 메뉴 (홈·채팅 패널 공용, 선택은 전역 영속)

struct ChatModelMenu: View {
    @Environment(AppState.self) private var app

    /// 바인딩을 주면 그 값을 읽고 쓴다(레시피 실행 시트의 1회성 선택).
    /// 없으면 앱 전역 채팅 모델을 읽고 쓴다.
    private let selection: Binding<ChatModelChoice>?

    init(selection: Binding<ChatModelChoice>? = nil) {
        self.selection = selection
    }

    private var current: ChatModelChoice {
        selection?.wrappedValue ?? app.chatModel
    }

    var body: some View {
        Menu {
            Section("Standard") {
                ForEach(ChatModelChoice.standardChoices, id: \.self) { modelButton($0) }
            }
            Section("Thinking") {
                ForEach(ChatModelChoice.thinkingChoices, id: \.self) { modelButton($0) }
            }
            Section("Local") {
                modelButton(.localQwen)
            }
        } label: {
            Text(current.displayName)
                .font(.caption)
        }
        .fixedSize()
        .controlSize(.small)
    }

    @ViewBuilder
    private func modelButton(_ choice: ChatModelChoice) -> some View {
        Button {
            if let selection {
                selection.wrappedValue = choice
            } else {
                app.setChatModel(choice)
            }
        } label: {
            if choice == current {
                Label(choice.displayName, systemImage: "checkmark")
            } else {
                Text(choice.displayName)
            }
        }
    }
}

// MARK: - AI 채팅 패널

struct ChatPanel: View {
    @Environment(AppState.self) private var app
    let scope: AppState.ChatScope
    var expanded = false
    @State private var input = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Label("Ask AI", systemImage: "sparkles")
                    .font(expanded ? .title3.weight(.semibold) : .callout.weight(.semibold))
                    .foregroundStyle(expanded ? Theme.accent : Color.secondary)
                Text(scopeHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            if app.chatMessages.isEmpty, expanded {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.accent.opacity(0.4))
                    Text("Ask anything across all your saved meetings.\ne.g. \"What did we decide about columnar?\"")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !app.chatMessages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(app.chatMessages) { message in
                                bubble(message).id(message.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    .frame(minHeight: expanded ? nil : 60,
                           maxHeight: expanded ? .infinity : 320)
                    .onChange(of: app.chatMessages.count) {
                        if let last = app.chatMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(placeholder, text: $input)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit(send)
                    .disabled(app.chatBusy)
                ChatModelMenu()
                if app.chatBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Ask", action: send)
                        .tint(Theme.accent)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !app.chatMessages.isEmpty {
                    Button {
                        app.chatMessages = []
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear conversation")
                }
            }
        }
        .padding(.horizontal, expanded ? 28 : 16)
        .padding(.top, expanded ? 24 : 12)
        .padding(.bottom, expanded ? 20 : 14)
        .background(expanded ? Theme.canvas : Color(nsColor: .controlBackgroundColor))
        .onAppear { app.ensureChatScope(scope) }
        .onChange(of: scope.key) {
            app.ensureChatScope(scope)
        }
    }

    private var scopeHint: String {
        switch scope {
        case .archive: return "· all meetings"
        case .live: return app.isRunning ? "· current meeting (live)" : "· this meeting"
        case .saved: return "· this meeting"
        }
    }

    private var placeholder: String {
        switch scope {
        case .archive:
            return "Ask about all your meetings…"
        case .live:
            return app.isRunning ? "Ask about the meeting in progress…" : "Ask about this meeting…"
        case .saved:
            return "Ask about this meeting…"
        }
    }

    private func send() {
        let question = input
        input = ""
        app.askChat(question, scope: scope)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            Text(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(message.role == .user
                            ? Theme.accent.opacity(0.12)
                            : Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Gemini API 키 입력 시트

struct GeminiKeySheet: View {
    let errorText: String?
    let canRemove: Bool
    let onSave: (String) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Gemini API Key", systemImage: "key.fill")
                .font(.headline)
            Text("Used by the Cloud backend (translation, minutes, chat). The key is stored only in the macOS Keychain. In cloud mode, meeting audio is sent to Google.\nGet a key: aistudio.google.com/apikey")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("AIza…", text: $key)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit { onSave(key) }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if canRemove {
                    Button("Remove Key", role: .destructive, action: onRemove)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save & Use Cloud") { onSave(key) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - 공용 소품

struct SpeakerChipLabel: View {
    let name: String
    let color: Color

    var body: some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .frame(minWidth: 64, alignment: .leading)
    }
}

struct BannerView: View {
    let text: String
    let color: Color
    var icon: String = "exclamationmark.triangle.fill"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(color.opacity(0.1))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var jargonDraft = ""
    @State private var editingRecipe: Recipe?
    @State private var isCreatingRecipe = false
    @State private var recipeError: String?
    @State private var accessibilityGranted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.system(size: 27, weight: .semibold, design: .serif))

                settingsCard("General") {
                    Picker("Backend", selection: Binding(
                        get: { app.backend },
                        set: { app.setBackend($0) }
                    )) {
                        Text("Local — Apple Translation + Qwen").tag(ProcessingBackend.local)
                        Text("Cloud — Gemini (higher quality)").tag(ProcessingBackend.cloud)
                    }
                    .pickerStyle(.radioGroup)
                    Text("The backend applies to translation and minutes. Cloud sends meeting audio to Google and requires an API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Set Gemini API Key…") { app.showGeminiKeyPrompt = true }
                        .controlSize(.small)
                    if let error = app.geminiKeychainError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.vermilion)
                            .textSelection(.enabled)
                    } else if app.hasGeminiKey {
                        Text("Key stored in Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider().padding(.vertical, 4)

                    Text("Local model")
                        .font(.subheadline.weight(.semibold))
                    Picker("", selection: Binding(
                        get: { app.localModelID },
                        set: { app.setLocalModelID($0) }
                    )) {
                        Text("Qwen3.5 4B — 2.3 GB, fast").tag(SummaryService.defaultModelID)
                        Text("Qwen3.5 9B — 5.2 GB, higher quality").tag("mlx-community/Qwen3.5-9B-MLX-4bit")
                        Text("Qwen3.8 4B — 2.3 GB, experimental").tag("SiddhJagani/Qwen3.8-4B-mlx-4Bit")
                        Text("Qwen3.8 9B — 5.2 GB, experimental").tag("SiddhJagani/Qwen3.8-9B-mlx-4Bit")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text("Used for minutes and local chat. A newly selected model downloads on first use. Qwen3.8 builds are community MLX conversions; quality is unverified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard("Language") {
                    languageRow("Transcription language") {
                        Picker("", selection: Binding(
                            get: { app.transcriptionLanguage },
                            set: { app.setTranscriptionLanguage($0) }
                        )) {
                            Text("English").tag("English")
                            Text("Multilingual").tag("Multilingual")
                        }
                        .fixedSize()
                        .labelsHidden()
                    }
                    Text("English is most accurate for English meetings. Multilingual auto-detects 25 languages (downloads a separate model on first use). Applies to the next recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    languageRow("Summary language") {
                        Picker("", selection: Binding(
                            get: { app.summaryLanguage },
                            set: { app.setSummaryLanguage($0) }
                        )) {
                            ForEach(LanguagePrefs.summaryOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .fixedSize()
                        .labelsHidden()
                    }

                    Divider().padding(.vertical, 4)

                    Toggle("Translate transcripts", isOn: Binding(
                        get: { app.translationEnabled },
                        set: { app.setTranslationEnabled($0) }
                    ))
                    if app.translationEnabled {
                        languageRow("Translation language") {
                            Picker("", selection: Binding(
                                get: { app.translationLanguage },
                                set: { app.setTranslationLanguage($0) }
                            )) {
                                ForEach(LanguagePrefs.translationOptions, id: \.self) { Text($0).tag($0) }
                            }
                            .fixedSize()
                            .labelsHidden()
                        }
                    }
                    Text("Translation is off when the app starts. Turn it on per meeting when you need it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 4)

                    Text("Internal jargon")
                        .font(.subheadline.weight(.semibold))
                    TextField("ECK, ECH, SA, Elastic, ECU", text: $jargonDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                        .onSubmit { app.setInternalJargon(jargonDraft) }
                    Text("Comma separated words. Used to correct misheard names and terms in transcripts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Save") { app.setInternalJargon(jargonDraft) }
                            .controlSize(.small)
                    }
                }

                settingsCard("Audio") {
                    Toggle("Echo filter", isOn: Binding(
                        get: { app.echoFilterEnabled },
                        set: { app.setEchoFilter($0) }
                    ))
                    Text("Filters remote voices leaking from your speakers into the mic.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Sync mute with Zoom", isOn: Binding(
                        get: { app.syncMuteWithZoom },
                        set: { app.setSyncMuteWithZoom($0) }
                    ))

                    Divider().padding(.vertical, 4)

                    HStack {
                        Text("Zoom speaker names")
                        Spacer()
                        Text(accessibilityGranted ? "Accessibility: granted" : "Accessibility: not granted")
                            .font(.caption)
                            .foregroundStyle(accessibilityGranted ? .secondary : Theme.vermilion)
                        if !accessibilityGranted {
                            Button("Open Accessibility Settings") {
                                NSWorkspace.shared.open(ZoomSpeakerTagger.accessibilitySettingsURL)
                            }
                            .controlSize(.small)
                        }
                    }
                }

                settingsCard("Meetings") {
                    Toggle("Meeting alerts (1 min before)", isOn: Binding(
                        get: { app.calendar.isEnabled },
                        set: { app.calendar.setEnabled($0) }
                    ))
                    Toggle("Auto-start with meeting apps", isOn: Binding(
                        get: { app.autoStartOnMeetingApp },
                        set: { app.setAutoStart($0) }
                    ))
                    Toggle("Countdown before auto-start (5s)", isOn: Binding(
                        get: { app.autoStartCountdown },
                        set: { app.setAutoStartCountdown($0) }
                    ))
                    Text("Shows a cancelable countdown instead of recording right away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Auto-start at calendar meeting time", isOn: Binding(
                        get: { app.autoStartAtCalendarTime },
                        set: { app.setAutoStartAtCalendarTime($0) }
                    ))
                    Divider().padding(.vertical, 4)
                    BriefSettingsRows(controller: app.briefing)
                }

                settingsCard("Recipes") {
                    Text("Predefined prompt templates for batch or meeting analysis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        ForEach(app.recipeStore.recipes) { recipe in
                            HStack(spacing: 10) {
                                Image(systemName: recipe.icon.isEmpty ? Recipe.defaultIcon : recipe.icon)
                                    .frame(width: 20)
                                    .foregroundStyle(Theme.accent)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(recipe.title)
                                            .font(.body.weight(.medium))
                                        if recipe.builtin {
                                            Text("Built-in")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.secondary.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(recipe.scopeDefault.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Edit") {
                                    editingRecipe = recipe
                                }
                                .controlSize(.small)

                                Button("Duplicate") {
                                    duplicateRecipe(recipe)
                                }
                                .controlSize(.small)

                                if !recipe.builtin {
                                    Button("Delete", role: .destructive) {
                                        runRecipeStoreAction {
                                            try app.recipeStore.delete(id: recipe.id)
                                        }
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 4)
                            if recipe.id != app.recipeStore.recipes.last?.id {
                                Divider()
                            }
                        }
                    }

                    if let recipeError {
                        Text(recipeError)
                            .font(.caption)
                            .foregroundStyle(Theme.vermilion)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button {
                            isCreatingRecipe = true
                        } label: {
                            Label("New recipe", systemImage: "plus")
                        }
                        .controlSize(.small)

                        Spacer()

                        Button("Reset built-ins") {
                            runRecipeStoreAction {
                                try app.recipeStore.resetBuiltins()
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }

            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            jargonDraft = app.internalJargon
            accessibilityGranted = ZoomSpeakerTagger.accessibilityTrusted(prompt: false)
            app.refreshGeminiKeyStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = ZoomSpeakerTagger.accessibilityTrusted(prompt: false)
        }
        .sheet(isPresented: $isCreatingRecipe) {
            RecipeEditorView(
                recipe: nil,
                onSave: { _ in isCreatingRecipe = false },
                onCancel: { isCreatingRecipe = false }
            )
        }
        .sheet(item: $editingRecipe) { recipe in
            RecipeEditorView(
                recipe: recipe,
                onSave: { _ in editingRecipe = nil },
                onCancel: { editingRecipe = nil }
            )
        }
    }

    private func duplicateRecipe(_ recipe: Recipe) {
        let copyTitle = "\(recipe.title) copy"
        let copyID = app.recipeStore.uniqueID(for: copyTitle)
        let copy = Recipe(
            id: copyID,
            title: copyTitle,
            icon: recipe.icon,
            builtin: false,
            scopeDefault: recipe.scopeDefault,
            modelHint: recipe.modelHint,
            outputLanguage: recipe.outputLanguage,
            system: recipe.system,
            prompt: recipe.prompt
        )
        runRecipeStoreAction {
            try app.recipeStore.upsert(copy)
        }
    }

    /// 레시피 저장소 작업을 실행하고 실패하면 카드 아래에 오류를 보여준다.
    private func runRecipeStoreAction(_ action: () throws -> Void) {
        do {
            try action()
            recipeError = nil
        } catch {
            recipeError = error.localizedDescription
        }
    }

    /// 라벨 왼쪽 + 컨트롤 오른쪽 정렬 행 (Granola식)
    private func languageRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
            Spacer()
            control()
        }
    }

    private func settingsCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.accent)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
    }
}
