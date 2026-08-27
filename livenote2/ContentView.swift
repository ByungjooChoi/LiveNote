import SwiftUI
import Translation

/// 메인 화면: 좌측 회의 목록 사이드바 + 우측 라이브/저장 회의 뷰.
struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var selection: SidebarItem? = .live

    enum SidebarItem: Hashable {
        case live
        case saved(URL)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            switch selection {
            case .saved(let url):
                SavedMeetingView(url: url)
                    .id(url)
            default:
                LiveMeetingView()
            }
        }
        // Apple Translation 세션은 이 modifier를 통해서만 열립니다 (EN→KO 온디바이스).
        // 사이드바 전환에도 세션이 유지되도록 최상위에 부착.
        .translationTask(app.translator.config) { session in
            await app.translator.serve(session: session, state: app)
        }
    }

    private static let upcomingTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label(app.isRunning ? "라이브 (듣는 중)" : "라이브", systemImage: "waveform")
                    .tag(SidebarItem.live)
            }
            if !app.calendar.todayUpcoming.isEmpty {
                Section("오늘 일정") {
                    ForEach(app.calendar.todayUpcoming) { item in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text("\(Self.upcomingTimeFormatter.string(from: item.start)) ~ \(Self.upcomingTimeFormatter.string(from: item.end))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.isNow(), !app.isRunning {
                                Button("지금 시작") {
                                    selection = .live
                                    app.startUpcomingMeeting(link: item.deepLink ?? item.webLink)
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .selectionDisabled(true)
                    }
                }
            }
            Section("저장된 회의") {
                if app.meetingStore.meetings.isEmpty {
                    Text("아직 저장된 회의가 없습니다")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(app.meetingStore.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                            .lineLimit(1)
                        Text("\(meeting.dateLabel) · \(meeting.rowCount)건 · \(meeting.durationLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(SidebarItem.saved(meeting.url))
                    .contextMenu {
                        Button("Finder에서 보기") {
                            NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
                        }
                        Button("삭제", role: .destructive) {
                            if selection == .saved(meeting.url) {
                                selection = .live
                            }
                            app.meetingStore.delete(meeting)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: Binding(
            get: { app.showGeminiKeyPrompt },
            set: { app.showGeminiKeyPrompt = $0 }
        )) {
            GeminiKeySheet(
                onSave: { app.saveGeminiKey($0) },
                onCancel: { app.showGeminiKeyPrompt = false }
            )
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
                    // 마이크 아이콘 = 뮤트 토글. 뮤트 중엔 "나" 채널을 엔진이 통째로 버림.
                    Button {
                        app.setMicMuted(!app.micMuted)
                    } label: {
                        Label(app.micMuted ? "뮤트" : "마이크",
                              systemImage: app.micMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.caption)
                            .foregroundStyle(app.micMuted ? .red : .green)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help(app.micMuted
                          ? "마이크 뮤트 중 — 내 목소리와 스피커 에코가 전사되지 않습니다. 클릭해서 해제 (⌘⇧M)"
                          : "클릭하면 마이크를 뮤트합니다. 말하지 않을 때 켜 두면 스피커 에코가 '나'로 잘못 전사되는 일이 없습니다 (⌘⇧M)")
                    // 입력 레벨 미터 — 말할 때 안 움직이면 마이크 신호가 안 들어오는 것.
                    // 뮤트 중에도 입력은 보여줌 (마이크는 살아 있고 앱이 버리는 중이라는 피드백).
                    ProgressView(value: Double(min(1.0, app.micLevel)))
                        .progressViewStyle(.linear)
                        .frame(width: 48)
                        .tint(app.micMuted ? .red : (app.micLevel > 0.05 ? .green : .gray))
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
            .help("스피커에서 나온 상대방 소리가 마이크로 들어와 '나'로 잘못 전사되는 것을 걸러냅니다. 실행 중에도 켜고 끌 수 있습니다.")

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

            // 클라우드 연결 표시등: 초록=연결됨, 주황=연결/재연결 중
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
                    Label("저장됨 — Finder에서 보기", systemImage: "folder")
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
            .tint(app.isRunning ? .red : .accentColor)
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
        if let calendarIssue = app.calendar.issueMessage {
            BannerView(text: calendarIssue, color: .orange)
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

    // MARK: 화자 칩 (클릭해서 이름 변경)

    @ViewBuilder
    private func speakerChip(for row: TranscriptRow) -> some View {
        let name = app.displayName(for: row)
        let color = Self.chipColor(channel: row.channel, slot: row.speakerSlot, name: row.speakerName)
        if row.speakerName != nil {
            // Zoom 태그로 자동 인식된 화자: 편집 불필요 (클릭 없음)
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

            // 캘린더 참석자 원클릭 후보 (상대방 화자에만)
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
                    .foregroundStyle(Color.accentColor)
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
            // 자동 인식 이름: 이름 기반 안정 해시로 색 고정 (세션·재실행 간 일관)
            if let name, !name.isEmpty {
                return slotColors[Self.stableHash(name) % slotColors.count]
            }
            guard let slot else { return Color.primary.opacity(0.55) }
            return slotColors[slot % slotColors.count]
        }
    }

    /// 실행 간 안정적인 문자열 해시 (Swift hashValue는 시드가 매번 달라짐)
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
                .foregroundStyle(.tertiary)
            Text("시작을 누르면 영어 음성을 전사하고 한국어로 번역합니다.\n마이크는 '\(app.myName)', 시스템 오디오(Zoom 등)는 화자별로 '상대방 1/2/3…'으로 나뉩니다.\n중지하면 ~/Documents/livenote2/ 에 en.md · ko.md · combined.md로 저장됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    // MARK: 헬퍼

    /// "번역 중…" 표시 여부 (모드별 정상 동작 조건)
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
        case .error: return .red
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

// MARK: - 저장된 회의 뷰 (읽기 전용)

struct SavedMeetingView: View {
    @Environment(AppState.self) private var app
    let url: URL
    @State private var meeting: SavedMeeting?

    var body: some View {
        Group {
            if let meeting {
                VStack(spacing: 0) {
                    savedHeader(meeting)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            SummaryCard(
                                summary: meeting.summary,
                                phase: app.summaryPhase,
                                onGenerate: { app.generateSummary(for: url) }
                            )
                            ForEach(meeting.rows) { row in
                                savedRow(row, meeting: meeting)
                            }
                        }
                        .padding(16)
                    }
                    Divider()
                    ChatPanel(scope: .saved(url))
                }
            } else {
                ContentUnavailableView("회의를 불러올 수 없습니다", systemImage: "exclamationmark.folder")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            meeting = app.meetingStore.load(url)
        }
        .onChange(of: app.summaryPhase) { _, newPhase in
            // 요약 생성이 끝나면 디스크에서 다시 읽어 화면 갱신
            if newPhase == .idle {
                meeting = app.meetingStore.load(url)
            }
        }
    }

    private func savedHeader(_ meeting: SavedMeeting) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text("전사 \(meeting.rows.count)건")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Finder에서 보기", systemImage: "folder")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func savedRow(_ row: TranscriptRow, meeting: SavedMeeting) -> some View {
        let name = MeetingStore.resolveName(row: row, myName: meeting.myName, speakerNames: meeting.speakerNames)
        let color = LiveMeetingView.chipColor(channel: row.channel, slot: row.speakerSlot, name: row.speakerName)
        return HStack(alignment: .top, spacing: 10) {
            SpeakerChipLabel(name: name, color: color)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.english)
                    .font(.body)
                    .textSelection(.enabled)
                if let korean = row.korean {
                    Text(korean)
                        .font(.callout)
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

// MARK: - 요약 카드

struct SummaryCard: View {
    let summary: String?
    let phase: AppState.SummaryPhase
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("회의 요약", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if phase == .generating {
                    ProgressView()
                        .controlSize(.small)
                    Text("생성 중… (최초 실행 시 모델 ~2.3GB 다운로드)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(summary == nil ? "요약 생성" : "다시 생성", action: onGenerate)
                        .controlSize(.small)
                }
            }
            if case .failed(let message) = phase {
                Text("요약 실패: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let summary {
                Divider()
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}

// MARK: - AI 채팅 패널 (Granola식 하단 대화창)

/// 회의 기록에 대한 질의응답. 범위: 라이브(진행 중 회의 실시간 질문 가능) /
/// 저장 회의 / 전체 아카이브. 모델은 상단 백엔드와 독립적으로 선택.
struct ChatPanel: View {
    @Environment(AppState.self) private var app
    let scope: AppState.ChatScope
    @State private var input = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Label("AI에게 질문", systemImage: "sparkles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(scopeHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
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
                    .frame(minHeight: 60, maxHeight: 320)
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color(nsColor: .controlBackgroundColor))
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
                            ? Color.accentColor.opacity(0.15)
                            : Color.primary.opacity(0.06))
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
            Text("클라우드 번역(Gemini Live Translate)에 사용됩니다. 키는 macOS 키체인에만 저장되며, 클라우드 모드에서는 회의 오디오가 Google로 전송됩니다.\n키 발급: aistudio.google.com/apikey")
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
