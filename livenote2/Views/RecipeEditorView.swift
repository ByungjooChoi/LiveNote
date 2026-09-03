import SwiftUI

/// 레시피 생성 및 편집 폼.
struct RecipeEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe?
    var onSave: ((Recipe) -> Void)?
    var onCancel: (() -> Void)?

    enum ScopeChoice: String, CaseIterable, Identifiable {
        case thisWeek = "This week"
        case lastDays = "Last N days"
        case currentMeeting = "This meeting"
        case manual = "Manual"

        var id: String { rawValue }
    }

    @State private var title: String
    @State private var icon: String
    @State private var scopeChoice: ScopeChoice
    @State private var lastDaysCount: Int
    @State private var modelHint: RecipeModelHint
    @State private var outputLanguage: String
    @State private var systemPrompt: String
    @State private var userPrompt: String

    init(recipe: Recipe? = nil, onSave: ((Recipe) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.recipe = recipe
        self.onSave = onSave
        self.onCancel = onCancel

        _title = State(initialValue: recipe?.title ?? "")
        _icon = State(initialValue: recipe?.icon ?? "doc.text")

        let initialScope: ScopeChoice
        let initialDays: Int
        switch recipe?.scopeDefault {
        case .thisWeek, .none:
            initialScope = .thisWeek
            initialDays = 14
        case .lastDays(let n):
            initialScope = .lastDays
            initialDays = n
        case .currentMeeting:
            initialScope = .currentMeeting
            initialDays = 14
        case .manual:
            initialScope = .manual
            initialDays = 14
        }
        _scopeChoice = State(initialValue: initialScope)
        _lastDaysCount = State(initialValue: initialDays)

        _modelHint = State(initialValue: recipe?.modelHint ?? .standard)
        _outputLanguage = State(initialValue: recipe?.outputLanguage ?? "Korean")
        _systemPrompt = State(initialValue: recipe?.system ?? "")
        _userPrompt = State(initialValue: recipe?.prompt ?? "Please analyze the following meetings:\n\n{{meetings}}")
    }

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isPromptMissingPlaceholder: Bool {
        !userPrompt.contains("{{meetings}}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(recipe == nil ? "New Recipe" : "Edit Recipe")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicSection
                    Divider()
                    scopeAndModelSection
                    Divider()
                    promptsSection
                }
                .padding(.horizontal, 2)
            }

            Divider()

            footer
        }
        .padding(20)
        .frame(minWidth: 560, maxWidth: 640, minHeight: 560, maxHeight: 700)
    }

    // MARK: - Subviews

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. Weekly Executive Summary", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Icon (SF Symbol)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: icon.isEmpty ? "doc.text" : icon)
                            .frame(width: 20, height: 20)
                            .foregroundStyle(Theme.accent)
                        TextField("doc.text", text: $icon)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }
                }
            }

            HStack {
                Text("Output language")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("e.g. Korean or English", text: $outputLanguage)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }
    }

    private var scopeAndModelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Default Scope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Default Scope", selection: $scopeChoice) {
                    ForEach(ScopeChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if scopeChoice == .lastDays {
                HStack {
                    Text("Number of days")
                        .font(.callout)
                    Spacer()
                    Stepper(value: $lastDaysCount, in: 1...365) {
                        Text("\(lastDaysCount) days")
                            .font(.callout.monospacedDigit())
                    }
                }
                .padding(.leading, 12)
            }

            HStack(alignment: .center) {
                Text("Model hint")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Model hint", selection: $modelHint) {
                    Text("Standard").tag(RecipeModelHint.standard)
                    Text("Thinking").tag(RecipeModelHint.thinking)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System Instructions (Optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $systemPrompt)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 120)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("User Prompt Template")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Use {{meetings}}, {{today}}, {{language}}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: $userPrompt)
                    .font(.body)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                if isPromptMissingPlaceholder {
                    Text("Warning: Prompt does not contain {{meetings}}. Meeting records will not be injected.")
                        .font(.caption)
                        .foregroundStyle(Theme.vermilion)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                if let onCancel {
                    onCancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                saveAction()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!isTitleValid)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func saveAction() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIcon = icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "doc.text" : icon.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedScope: RecipeScopeDefault
        switch scopeChoice {
        case .thisWeek:
            resolvedScope = .thisWeek
        case .lastDays:
            resolvedScope = .lastDays(lastDaysCount)
        case .currentMeeting:
            resolvedScope = .currentMeeting
        case .manual:
            resolvedScope = .manual
        }

        let recipeID: String
        let builtin: Bool
        if let existing = recipe {
            recipeID = existing.id
            builtin = existing.builtin
        } else {
            recipeID = app.recipeStore.uniqueID(for: cleanTitle)
            builtin = false
        }

        let saved = Recipe(
            id: recipeID,
            title: cleanTitle,
            icon: cleanIcon,
            builtin: builtin,
            scopeDefault: resolvedScope,
            modelHint: modelHint,
            outputLanguage: outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines),
            system: systemPrompt,
            prompt: userPrompt
        )

        app.recipeStore.upsert(saved)

        if let onSave {
            onSave(saved)
        } else {
            dismiss()
        }
    }
}
