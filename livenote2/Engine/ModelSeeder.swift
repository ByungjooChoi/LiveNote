import Foundation

/// 번들 동봉 모델을 최초 실행 시 캐시 위치로 복사 (다운로드 생략).
///
/// `BUNDLE_MODELS=1 ./script/package.sh`로 빌드하면 FluidAudio 모델
/// (Parakeet v2 + LS-EEND + VAD + Diarizer pyannote/wespeaker, 약 0.5GB)이 앱 Resources/BundledModels에 동봉되고,
/// 첫 실행 때 `~/Library/Application Support/FluidAudio/Models`로 복사된다.
/// Diarizer 모델: `speaker-diarization-coreml` (`pyannote_segmentation.mlmodelc`, `wespeaker_v2.mlmodelc`).
/// Qwen(2.3GB+)은 GitHub 릴리스 자산 2GB 한도 때문에 동봉하지 않는다 (첫 사용 시 다운로드).
enum ModelSeeder {

    static func seedIfNeeded() {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("BundledModels", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.path) else { return }
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled, to: target)
            AppLog.write("app", "번들 모델 시딩 완료 → \(target.path)")
        } catch {
            AppLog.write("app", "번들 모델 시딩 실패: \(error.localizedDescription)")
        }
    }
}
