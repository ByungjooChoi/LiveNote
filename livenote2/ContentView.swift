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
        case live
        case meeting(URL)
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
                onSave: { app.saveGeminiKey($0) },
                onCancel: { app.showGeminiKeyPrompt = false }
            )
        }
        .onChange(of: app.isRunning) { _, running in
            if running { screen = .live }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .home:
            HomeView(screen: $screen)
        case .chat:
            ChatFullView()
        case .live:
            LiveMeetingView()
        case .meeting(let url):
            MeetingDetailView(url: url, screen: $screen)
                .id(url)
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
                Text("livenote")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 16)

            railItem("홈", icon: "house.fill", target: .home,
                     selected: isHome)
            railItem("채팅", icon: "bubble.left.and.bubble.right.fill", target: .chat,
                     selected: screen == .chat)
            if app.isRunning || !app.rows.isEmpty {
                railItem(app.isRunning ? "라이브 · 듣는 중" : "라이브",
                         icon: "waveform", target: .live,
                         selected: screen == .live,
                         dot: app.isRunning ? Theme.vermilion : nil)
            }

            Spacer()

            if app.isRunning {
                HStack(spacing: 6) {
                    Circle().fill(Theme.vermilion).frame(width: 7, height: 7)
                    Text("기록 중")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.leading, 10)
            }
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

// MARK: - 홈 (Coming up + 회의 피드)

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Binding var screen: ContentView.Screen

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let sectionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E)"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Coming up")
                    .font(.system(size: 27, weight: .semibold, design: .serif))
                comingUpCard

                Text("회의 기록")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 6)
                meetingFeed
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Coming up 카드

    private var comingUpCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.isRunning {
                HStack(spacing: 10) {
                    Circle().fill(Theme.vermilion).frame(width: 9, height: 9)
                    Text("듣는 중 — 전사 \(app.rows.count)건")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("열기") { screen = .live }
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
                    Text("새 회의 기록")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("시작") {
                        app.start()
                        screen = .live
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                }
                .padding(14)
                if !app.calendar.todayUpcoming.isEmpty {
                    Divider().padding(.horizontal, 14)
                }
            }

            ForEach(app.calendar.todayUpcoming) { item in
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
                    Spacer()
                    if item.isNow(), !app.isRunning {
                        Button("지금 시작") {
                            app.startUpcomingMeeting(link: item.deepLink ?? item.webLink)
                            screen = .live
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.vermilion)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            if app.calendar.todayUpcoming.isEmpty && !app.isRunning {
                Text("오늘 남은 일정이 없습니다")
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
                label = "오늘"
            } else if calendar.isDateInYesterday(day) {
                label = "어제"
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

    @ViewBuilder
    private var meetingFeed: some View {
        if app.meetingStore.meetings.isEmpty {
            Text("아직 저장된 회의가 없습니다. 첫 회의를 시작해 보세요.")
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
            Button("Finder에서 보기") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
            }
            Button("삭제", role: .destructive) {
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
                                Text("회의록 생성 중…")
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
                        } else {
                            VStack(spacing: 10) {
                                Text("아직 회의록이 없습니다")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Button("회의록 생성") { app.generateSummary(for: url) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.accent)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity)
                            .themedCard()
                        }

                        if case .failed(let message) = app.summaryPhase {
                            Text("요약 실패: \(message)")
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
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                screen = .home
            } label: {
                Label("홈", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            Spacer()
            Toggle("전사 보기", isOn: $showTranscript)
                .toggleStyle(.checkbox)
                .font(.caption)
            Button {
                app.generateSummary(for: url)
            } label: {
                Label("회의록 다시 생성", systemImage: "arrow.clockwise")
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
        let duration = total >= 60 ? "\(total / 60)분" : "\(total)초"
        let names = Set(meeting.rows.map {
            MeetingStore.resolveName(row: $0, myName: meeting.myName, speakerNames: meeting.speakerNames)
        })
        return Text("\(MeetingStore.longDateLabel(meeting.startedAt)) · \(duration) · 참석 \(names.count)명 · 전사 \(meeting.rows.count)건")
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
    var body: some View {
        VStack(spacing: 0) {
            ChatPanel(scope: .archive, expanded: true)
        }
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

            Spacer()

            if app.isRunning {
                HStack(spacing: 4) {
                    Button {
                        app.setMicMuted(!app.micMuted)
                    } label: {
                        Label(app.micMuted ? "뮤트" : "마이크",
                              systemImage: app.micMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.caption)
                            .foregroundStyle(app.micMuted ? Theme.vermilion : .green)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help(app.micMuted
                          ? "마이크 뮤트 중 — 내 목소리와 스피커 에코가 전사되지 않습니다. 클릭해서 해제 (⌘⇧M)"
                          : "클릭하면 마이크를 뮤트합니다 (⌘⇧M). Zoom 뮤트와 자동 동기화됩니다.")
                    ProgressView(value: Double(min(1.0, app.micLevel)))
                        .progressViewStyle(.linear)
                        .frame(width: 48)
                        .tint(app.micMuted ? Theme.vermilion : (app.micLevel > 0.05 ? .green : .gray))
                }
                Label("시스템 오디오", systemImage: app.systemAudioAvailable ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(app.systemAudioAvailable ? .green : .orange)
            }

            Toggle("에코 필터", isOn: Binding(
                get: { app.echoFilterEnabled },
                set: { app.setEchoFilter($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("스피커에서 나온 상대방 소리가 마이크로 들어와 '나'로 잘못 전사되는 것을 걸러냅니다.")

            Toggle("번역", isOn: Binding(
                get: { app.translationEnabled },
                set: { app.setTranslationEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("한국어 번역 표시를 켜고 끕니다. 처리 백엔드(로컬/클라우드)는 옆 메뉴에서 선택.")

            Picker("", selection: Binding(
                get: { app.backend },
                set: { app.setBackend($0) }
            )) {
                Text("로컬").tag(ProcessingBackend.local)
                Text("클라우드").tag(ProcessingBackend.cloud)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("처리 백엔드 — 번역·요약의 제공자를 결정합니다.\n로컬: Apple 번역 + Qwen 요약. 오디오가 Mac 밖으로 나가지 않습니다.\n클라우드: Gemini 번역·요약 (품질 우위). 회의 오디오가 Google로 전송됩니다. API 키 필요.")

            if app.backend == .cloud, app.translationEnabled, app.isRunning, let status = app.cloudStatus {
                Circle()
                    .fill(status == .connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .help(status == .connected
                          ? "클라우드 번역 연결됨"
                          : "클라우드 번역 연결 중 또는 재연결 중 — 로그: ~/Documents/livenote2/logs/cloud.log")
            }

            if !app.isRunning, let savedURL = app.currentMeetingURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                } label: {
                    Label("저장됨", systemImage: "folder")
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
            BannerView(text: zoomTagIssue, color: .orange)
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
                    Text("번역 중…")
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
                .help("Zoom에서 자동 인식된 화자")
        } else {
            Button {
                draftName = name
                editingRowID = row.id
            } label: {
                SpeakerChipLabel(name: name, color: color)
            }
            .buttonStyle(.plain)
            .help("클릭해서 화자 이름 변경")
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
            Text(row.channel == .me ? "내 이름" : "화자 이름")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("이름", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commitRename(for: row) }

            if row.channel == .them, !app.attendeeCandidates.isEmpty {
                Divider()
                Text("캘린더 참석자")
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
                Button("저장") { commitRename(for: row) }
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
            Text("시작을 누르면 영어 음성을 전사하고 한국어로 번역합니다.\nZoom 회의에서는 화자 이름이 자동으로 붙습니다.")
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
            return app.rows.isEmpty ? "대기 중" : "중지됨 — 전사 \(app.rows.count)건"
        case .preparing(let message):
            return message
        case .listening:
            return "듣는 중"
        case .error:
            return "오류"
        }
    }

    private var buttonTitle: String {
        app.isRunning ? "중지" : "시작"
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
                Label("회의록", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                Spacer()
                if phase == .generating {
                    ProgressView()
                        .controlSize(.small)
                    Text("생성 중…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(summary == nil ? "생성" : "다시 생성", action: onGenerate)
                        .controlSize(.small)
                }
            }
            if case .failed(let message) = phase {
                Text("요약 실패: \(message)")
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

// MARK: - AI 채팅 패널

struct ChatPanel: View {
    @Environment(AppState.self) private var app
    let scope: AppState.ChatScope
    var expanded = false
    @State private var input = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Label("AI에게 질문", systemImage: "sparkles")
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
                    Text("저장된 모든 회의 기록에 대해 물어보세요.\n예: \"이번 주 Pangobooks 논의 요점은?\", \"columnar 관련 결정이 뭐였지?\"")
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
                Menu {
                    ForEach(ChatModelChoice.allCases, id: \.self) { choice in
                        Button {
                            app.setChatModel(choice)
                        } label: {
                            if choice == app.chatModel {
                                Label(choice.displayName, systemImage: "checkmark")
                            } else {
                                Text(choice.displayName)
                            }
                        }
                    }
                } label: {
                    Text(app.chatModel.displayName)
                        .font(.caption)
                }
                .fixedSize()
                .controlSize(.small)
                if app.chatBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("질문", action: send)
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
                    .help("대화 지우기")
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
        case .archive: return "· 전체 회의 기록 대상"
        case .live: return app.isRunning ? "· 진행 중인 회의 대상 (실시간)" : "· 이 회의 대상"
        case .saved: return "· 이 회의 대상"
        }
    }

    private var placeholder: String {
        switch scope {
        case .archive:
            return "전체 회의 기록에 대해 질문…"
        case .live:
            return app.isRunning ? "진행 중인 회의에 대해 질문…" : "이 회의에 대해 질문…"
        case .saved:
            return "이 회의에 대해 질문…"
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
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Gemini API 키", systemImage: "key.fill")
                .font(.headline)
            Text("클라우드 백엔드(번역·요약·채팅)에 사용됩니다. 키는 macOS 키체인에만 저장되며, 클라우드 모드에서는 회의 오디오가 Google로 전송됩니다.\n키 발급: aistudio.google.com/apikey")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("AIza…", text: $key)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit { onSave(key) }
            HStack {
                Spacer()
                Button("취소", action: onCancel)
                Button("저장하고 클라우드 사용") { onSave(key) }
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.1))
    }
}
