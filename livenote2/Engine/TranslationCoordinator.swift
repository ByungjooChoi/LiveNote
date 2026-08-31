import Foundation
import Observation
import Translation

/// Apple Translation framework(온디바이스, EN→KO) 연동.
///
/// TranslationSession은 직접 생성할 수 없고 SwiftUI의 .translationTask에서만 받을 수 있어서,
/// ContentView가 이 코디네이터의 config로 translationTask를 열고
/// 세션이 살아 있는 동안 serve()가 번역 요청 큐를 소비하는 구조입니다.
@MainActor
@Observable
final class TranslationCoordinator {

    /// nil이면 translationTask 비활성. start 시점에 activate()로 켭니다.
    var config: TranslationSession.Configuration?

    /// 번역 레이어 문제 안내 (언어팩 미설치 등). nil이면 정상.
    var issueMessage: String?

    func activate() {
        let target = LanguagePrefs.translationCode
        // 언어 설정이 바뀌었으면 세션 재구성
        if let config, config.target == Locale.Language(identifier: target) { return }
        config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: target)
        )
    }

    /// translationTask 클로저에서 호출됨. 세션이 유효한 동안 요청 큐를 소비.
    func serve(session: TranslationSession, state: AppState) async {
        do {
            // 한국어 언어팩이 없으면 시스템 다운로드 시트가 뜹니다 (최초 1회)
            try await session.prepareTranslation()
            issueMessage = nil
        } catch {
            issueMessage = "Translation language pack unavailable — English transcription continues. (\(error.localizedDescription))"
        }

        for await request in state.translationRequests() {
            do {
                let response = try await session.translate(request.text)
                state.applyTranslation(response.targetText, to: request.rowID)
                if issueMessage != nil { issueMessage = nil }
            } catch {
                state.applyTranslation(nil, to: request.rowID)
                issueMessage = "Translation failed — English transcription continues. (\(error.localizedDescription))"
            }
        }
    }
}
