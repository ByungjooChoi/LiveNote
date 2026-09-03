import SwiftUI

/// 레시피 실행 대화상자 (범위 선택, 회의 프리뷰/체크박스, 모델/언어 선택, 실행).
struct RecipeRunSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe
    var currentMeeting: URL? = nil
    var onFinished: () -> Void

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

    init(recipe: Recipe, currentMeeting: URL? = nil, onFinished: @escaping () -> Void) {
        self.recipe = recipe
        self.currentMeeting = currentMeeting
        self.onFinished = onFinished

        switch recipe.scopeDefault {
        case .thisWeek:
            _selectedTab = State(initialValue: .thisWeek)
        case .lastDays(let n):
            _selectedTab = State(initialValue: .last14Days)
            _lastDaysCount = State(initialValue: n)
        case .currentMeeting:
            if currentMeeting != nil {
                _selectedTab = State(initialValue: .thisMeeting)
            } else {
                _selectedTab = State(initialValue: .thisWeek)
            }
        case .manual:
            _selectedTab = State(initialValue: .manual)
        }

        _selectedModel = State(initialValue: .gemini37Flash)
        _outputLanguage = State(initialValue: recipe.outputLanguage)
    }

    private var effectiveScope: RecipeScope {
        switch selectedTab {
        case .thisWeek:
            return .thisWeek
        case .last14Days:
            return .lastDays(lastDaysCount)
        case .thisMeeting:
            if let url = currentMeeting {
                return .currentMeeting(url)
            }
            return .thisWeek
        case .manual:
            return .manual(Array(selectedMeetingURLs))
        }
    }

    private var resolvedMeetings: [MeetingSummary] {
        app.recipeMeetings(for: effectiveScope)
    }

    private var isCloudModelWithoutKey: Bool {
        !app.hasGeminiKey && selectedModel != .localQwen
    }

    private var canRun: Bool {
        !resolvedMeetings.isEmpty && !app.isRecipeRunning && !isCloudModelWithoutKey
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
            selectedModel = RecipeRunner.defaultModel(for: recipe, userChoice: app.chatModel)
            if selectedTab == .manual && selectedMeetingURLs.isEmpty {
                let initial = app.recipeMeetings(for: RecipeScope(default: recipe.scopeDefault, currentMeeting: currentMeeting))
                selectedMeetingURLs = Set(initial.map { $0.url })
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: recipe.icon.isEmpty ? "doc.text" : recipe.icon)
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
                Text("This week").tag(ScopeTab.thisWeek)
                Text(lastDaysLabel).tag(ScopeTab.last14Days)
                Text("This meeting")
                    .tag(ScopeTab.thisMeeting)
                Text("Choose...").tag(ScopeTab.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: selectedTab) { _, newTab in
                if newTab == .manual && selectedMeetingURLs.isEmpty {
                    let current = app.recipeMeetings(for: previousScope(for: newTab))
                    selectedMeetingURLs = Set(current.map { $0.url })
                }
            }
        }
    }

    private var lastDaysLabel: String {
        lastDaysCount == 14 ? "Last 14 days" : "Last \(lastDaysCount) days"
    }

    private func previousScope(for tab: ScopeTab) -> RecipeScope {
        switch tab {
        case .thisWeek: return .thisWeek
        case .last14Days: return .lastDays(lastDaysCount)
        case .thisMeeting:
            return currentMeeting.map { .currentMeeting($0) } ?? .thisWeek
        case .manual: return .thisWeek
        }
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
                                selectedTab = .manual
                            }
                        }
                    }
                }
            }
            .padding(10)
            .themedCard()
            .frame(maxHeight: 180)
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
                Picker("Model", selection: $selectedModel) {
                    Section("Standard") {
                        ForEach(ChatModelChoice.standardChoices, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    Section("Thinking") {
                        ForEach(ChatModelChoice.thinkingChoices, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    Section("Local") {
                        Text(ChatModelChoice.localQwen.displayName).tag(ChatModelChoice.localQwen)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if isCloudModelWithoutKey {
                Text("No Gemini API key: runs on the local model, quality may be lower")
                    .font(.caption)
                    .foregroundStyle(Theme.vermilion)
            } else if !app.hasGeminiKey {
                Text("No Gemini API key: runs on the local model, quality may be lower")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        Task {
            let success = await app.runRecipe(
                recipe,
                scope: effectiveScope,
                model: selectedModel,
                language: outputLanguage
            )
            if success {
                dismiss()
                onFinished()
            }
        }
    }
}
