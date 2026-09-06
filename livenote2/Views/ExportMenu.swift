import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 내보내기 상태 결과.
enum ExportStatus: Equatable, Sendable {
    case exported(URL)
    case copied
    case failed(String)
}

/// 내보내기 및 복사 UI 피드백 상태 관리.
@MainActor @Observable final class ExportFeedback {
    var message: String?
    var isCopied = false
    var isExported = false

    private let resetDelay: Duration
    private var copyTimer: Task<Void, Never>?
    private var exportTimer: Task<Void, Never>?

    init(resetDelay: Duration = .seconds(1.5)) {
        self.resetDelay = resetDelay
    }

    func apply(_ status: ExportStatus) {
        switch status {
        case .copied:
            copyTimer?.cancel()
            isCopied = true
            let delay = resetDelay
            copyTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.isCopied = false
            }
        case .exported:
            exportTimer?.cancel()
            isExported = true
            let delay = resetDelay
            exportTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.isExported = false
            }
        case .failed(let msg):
            message = msg
        }
    }

    func dismiss() {
        message = nil
    }

    func cancelTimers() {
        copyTimer?.cancel()
        copyTimer = nil
        exportTimer?.cancel()
        exportTimer = nil
    }
}

/// 클립보드 쓰기 도우미 (테스트 주입 지원).
@MainActor
enum ClipboardWriter {
    /// Returns .copied on success, .failed(message) when the write returns false. `write` is injectable for tests.
    static func copy(_ text: String, write: @MainActor (String) -> Bool = ClipboardWriter.systemWrite) -> ExportStatus {
        if write(text) {
            return .copied
        } else {
            return .failed("Copy failed: clipboard write was rejected")
        }
    }

    static func systemWrite(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }
}

/// 회의 및 채팅/레시피 공용 내보내기 메뉴.
struct ExportMenu: View {
    var isCompact: Bool = false
    let makeSource: () -> ExportSource?
    var includeTranscriptToggle: Binding<Bool>? = nil
    let onStatus: (ExportStatus) -> Void

    init(
        isCompact: Bool = false,
        makeSource: @escaping () -> ExportSource?,
        includeTranscriptToggle: Binding<Bool>? = nil,
        onStatus: @escaping (ExportStatus) -> Void
    ) {
        self.isCompact = isCompact
        self.makeSource = makeSource
        self.includeTranscriptToggle = includeTranscriptToggle
        self.onStatus = onStatus
    }

    var body: some View {
        Menu {
            Button("Markdown…") {
                startExport(format: .markdown)
            }
            Button("HTML…") {
                startExport(format: .html)
            }
            if let toggle = includeTranscriptToggle {
                Divider()
                Toggle("Include transcript", isOn: toggle)
            }
        } label: {
            if isCompact {
                Image(systemName: "square.and.arrow.up")
                    .help("Export…")
            } else {
                Label("Export…", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
        }
    }

    nonisolated static func makeCompletion(
        document: ExportDocument,
        transcriptIncluded: Bool,
        onStatus: @escaping @MainActor (ExportStatus) -> Void
    ) -> (URL?) -> Void {
        return { targetURL in
            guard let targetURL else { return }
            let status: ExportStatus
            do {
                try MeetingExporter.write(document, to: targetURL)
                let parentDir = targetURL.deletingLastPathComponent().path
                UserDefaults.standard.set(parentDir, forKey: "exportLastDirectory")

                AppLog.write(
                    "export",
                    "내보내기 \(document.format.fileExtension) \(document.data.count)B transcript=\(transcriptIncluded)"
                )
                status = .exported(targetURL)
            } catch {
                let msg = "Export failed: \(error.localizedDescription)"
                AppLog.write("export", msg)
                status = .failed(msg)
            }

            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    onStatus(status)
                }
            } else {
                Task { @MainActor in
                    onStatus(status)
                }
            }
        }
    }

    @MainActor
    private func startExport(format: ExportFormat) {
        guard let source = makeSource() else {
            return
        }

        let document: ExportDocument
        do {
            document = try MeetingExporter.document(
                markdown: source.markdown,
                title: source.title,
                format: format,
                date: source.date
            )
        } catch {
            let msg = "Export failed: \(error.localizedDescription)"
            AppLog.write("export", msg)
            onStatus(.failed(msg))
            return
        }

        let transcriptIncluded = includeTranscriptToggle?.wrappedValue ?? false
        let completion = Self.makeCompletion(
            document: document,
            transcriptIncluded: transcriptIncluded,
            onStatus: onStatus
        )

        let panel = NSSavePanel()
        panel.canCreateDirectories = true

        if format == .markdown {
            if let mdType = UTType(filenameExtension: "md") {
                panel.allowedContentTypes = [mdType]
            } else {
                panel.allowedContentTypes = [.plainText]
            }
        } else {
            panel.allowedContentTypes = [.html]
        }

        panel.nameFieldStringValue = document.fileName

        if let savedPath = UserDefaults.standard.string(forKey: "exportLastDirectory"),
           !savedPath.isEmpty,
           FileManager.default.fileExists(atPath: savedPath) {
            panel.directoryURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }

        panel.begin { [completion] response in
            guard response == .OK, let targetURL = panel.url else { return }
            completion(targetURL)
        }
    }
}
