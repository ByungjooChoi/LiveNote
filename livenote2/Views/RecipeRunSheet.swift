import SwiftUI

/// 레시피 실행 대화상자 (범위 선택, 회의 프리뷰/체크박스, 모델/언어 선택, 실행).
struct RecipeRunSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe
    var currentMeeting: URL? = nil

    enum ScopeTab: String, CaseIterable, Identifiable {
        case thisWeek = "This week"
        case last14Days = "Last 14 days"
        case thisMeeting = "This meeting"
        case manual = "Choose..."

        var id: String { rawValue }
    }

    @State private var selectedTab: ScopeTab
    @State private var lastDaysCount: Int = 14
    @State private var selectedMeetingURLs: Set<URL> = []
    @State private var selectedModel: ChatModelChoice
    @State private var outputLanguage: String
    @State private var runTask: Task<Void, Never>?
    /// 행 토글로 Choose...에 들어온 경우: 계산된 선택 집합을 그대로 두고 재시딩하지 않는다.
    @State private var enteredManualByRowToggle = false

    init(recipe: Recipe, currentMeeting: URL? = nil) {
        self.recipe = recipe
        self.currentMeeting = currentMeeting

        switch recipe.scopeDefault {
        case .thisWeek:
            _selectedTab = State(initialValue: .thisWeek)
        case .lastDays(let n):
            _selectedTab = State(initialValue: .last14Days)
            _lastDaysCount = State(initialValue: n)
        case .currentMeeting:
            // 열린 회의가 없으면 빈 Choose... 로 시작한다. 다른 범위로 바꿔치기하면 여러 회의가 섞인다.
            _selectedTab = State(initialValue: currentMeeting != nil ? .thisMeeting : .manual)
        case .manual:
            _selectedTab = State(initialValue: .manual)
        }

        _selectedModel = State(initialValue: .gemini37Flash)
        _outputLanguage = State(initialValue: recipe.outputLanguage)
    }

    /// 열린 회의가 없으면 "This meeting" 세그먼트 자체를 내보내지 않는다.
    private var availableTabs: [ScopeTab] {
        currentMeeting == nil
            ? [.thisWeek, .last14Days, .manual]
            : ScopeTab.allCases
    }

    private func scope(for tab: ScopeTab) -> RecipeScope? {
        switch tab {
        case .thisWeek:
            return .thisWeek
        case .last14Days:
            return .lastDays(lastDaysCount)
        case .thisMeeting:
            return currentMeeting.map { RecipeScope.currentMeeting($0) }
        case .manual:
            return .manual(Array(selectedMeetingURLs))
        }
    }

    /// `.thisMeeting`은 열린 회의가 있을 때만 존재한다. 없으면 세그먼트도 없으므로 여기 오지 않는다.
    private var effectiveScope: RecipeScope {
        scope(for: selectedTab) ?? .manual(Array(selectedMeetingURLs))
    }

    private var resolvedMeetings: [MeetingSummary] {
        app.recipeMeetings(for: effectiveScope)
    }

    private var canRun: Bool {
        !resolvedMeetings.isEmpty && !app.isRecipeRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scopeSection
                    meetingsSection
                    optionsSection
                }
                .padding(.horizontal, 2)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 540, maxWidth: 620, minHeight: 520, maxHeight: 620)
        .onAppear {
            app.lastRecipeError = nil
            selectedModel = RecipeRunner.defaultModel(for: recipe, userChoice: app.chatModel)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: recipe.icon.isEmpty ? Recipe.defaultIcon : recipe.icon)
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title)
                    .font(.title3.weight(.semibold))
                Text("Run recipe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scope")
                .font(.subheadline.weight(.semibold))

            Picker("Scope", selection: $selectedTab) {
                ForEach(availableTabs) { tab in
                    Text(label(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: selectedTab) { oldTab, newTab in
                guard newTab == .manual else { return }
                // 행 토글로 들어온 경우는 이미 계산된 선택을 쓴다. 세그먼트로 직접 넘어온 경우만
                // 직전 범위가 고른 회의를 체크 상태로 옮긴다(이전 수동 선택은 버린다).
                if enteredManualByRowToggle {
                    enteredManualByRowToggle = false
                    return
                }
                guard let previous = scope(for: oldTab) else { return }
                selectedMeetingURLs = Set(app.recipeMeetings(for: previous).map { $0.url })
            }
        }
    }

    private func label(for tab: ScopeTab) -> String {
        tab == .last14Days ? "Last \(lastDaysCount) days" : tab.rawValue
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Meetings")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if resolvedMeetings.isEmpty {
                    Text("No meetings in this range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(effectiveScope.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 목록은 자체 ScrollView 안에서만 스크롤한다(행 압축 방지).
            ScrollView {
                VStack(spacing: 4) {
                    if selectedTab == .manual {
                        if app.meetingStore.meetings.isEmpty {
                            Text("No recorded meetings found.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 16)
                        } else {
                            ForEach(app.meetingStore.meetings) { meeting in
                                let isSelected = selectedMeetingURLs.contains(meeting.url)
                                meetingToggleRow(
                                    title: meeting.title,
                                    dateLabel: meeting.dateLabel,
                                    isSelected: isSelected
                                ) {
                                    if isSelected {
                                        selectedMeetingURLs.remove(meeting.url)
                                    } else {
                                        selectedMeetingURLs.insert(meeting.url)
                                    }
                                }
                            }
                        }
                    } else {
                        let meetings = resolvedMeetings
                        if meetings.isEmpty {
                            Text("No meetings in this range")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 16)
                        } else {
                            ForEach(meetings) { meeting in
                                meetingToggleRow(
                                    title: meeting.title,
                                    dateLabel: meeting.dateLabel,
                                    isSelected: true
                                ) {
                                    // 어떤 행이든 토글 해제 시 manual 모드로 전환하고 현재 목록에서 제외
                                    var newSelection = Set(meetings.map { $0.url })
                                    newSelection.remove(meeting.url)
                                    selectedMeetingURLs = newSelection
                                    enteredManualByRowToggle = true
                                    selectedTab = .manual
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(10)
            .themedCard()
        }
    }

    private func meetingToggleRow(
        title: String,
        dateLabel: String,
        isSelected: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(dateLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ChatModelMenu(selection: $selectedModel)
            }

            if !app.hasGeminiKey {
                Text("No Gemini API key: runs on the local model, quality may be lower")
                    .font(.caption)
                    .foregroundStyle(selectedModel == .localQwen ? Color.secondary : Theme.vermilion)
            }

            HStack {
                Text("Output language")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                TextField("Language", text: $outputLanguage)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = app.lastRecipeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.vermilion)
                    .textSelection(.enabled)
            }

            HStack {
                if app.isRecipeRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running recipe...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    runTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Run") {
                    runAction()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!canRun)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func runAction() {
        let scope = effectiveScope
        let model = selectedModel
        let language = outputLanguage
        runTask = Task {
            let success = await app.runRecipe(
                recipe,
                scope: scope,
                model: model,
                language: language
            )
            if success {
                dismiss()
            }
        }
    }
}
