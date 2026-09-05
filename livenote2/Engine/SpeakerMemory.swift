import Foundation

/// 성문 등록 결과 보고서 (성공 화자 목록, 충돌 발생 화자 목록, 에러 메시지 목록, 상세 로그)
public struct EnrollmentReport: Equatable, Sendable {
    public var enrolled: [String]
    public var conflicts: [String]
    public var errors: [String]
    public var log: [String]

    public init(
        enrolled: [String] = [],
        conflicts: [String] = [],
        errors: [String] = [],
        log: [String] = []
    ) {
        self.enrolled = enrolled
        self.conflicts = conflicts
        self.errors = errors
        self.log = log
    }
}

/// 화자 명명, 성문 매칭, 등록 및 충돌 관리를 담당하는 서비스.
@MainActor
struct SpeakerMemory {
    let store: any VoiceprintStoring

    init(store: any VoiceprintStoring) {
        self.store = store
    }

    /// 회의 전사 행들에 대해 화자 이름을 배정.
    /// 우선순위: Zoom 태그(.zoom) > 확신 성문 매칭(.voice) > 기존 슬롯 이름(.slot) > 폴백 이름(.slot)
    /// 마진 미달로 확신하지 못할 때는 candidateNames(최대 2명)를 기록.
    /// 수동 지정(.manual) 행은 절대 덮어쓰지 않음.
    func assignNames(
        rows: [TranscriptRow],
        diarization: OfflineDiarization?,
        zoomName: (TranscriptRow) -> String?,
        fallbackName: String?,
        existingSlotNames: [Int: String]
    ) -> (rows: [TranscriptRow], clusterNames: [String: String], log: [String]) {
        var log: [String] = []
        var clusterNames: [String: String] = [:]
        var clusterMatches: [String: VoiceMatch] = [:]

        // 1. 다이어라이제이션 클러스터별 중심 임베딩으로 성문 매칭 수행 (isMe 제외)
        if let diarization {
            for clusterID in diarization.clusterIDs {
                if let centroid = diarization.centroid(for: clusterID) {
                    let match = store.match(centroid.embedding, excludingMe: true)
                    clusterMatches[clusterID] = match
                    if match.confident, let person = match.person {
                        clusterNames[clusterID] = person.name
                        log.append("[SpeakerMemory] Cluster \(clusterID) matched voice '\(person.name)' (d1: \(String(format: "%.3f", match.d1)), d2: \(String(format: "%.3f", match.d2)))")
                    } else if !match.candidates.isEmpty {
                        let candidateNames = match.candidates.map(\.name).joined(separator: ", ")
                        log.append("[SpeakerMemory] Cluster \(clusterID) ambiguous voice match, candidates: [\(candidateNames)] (d1: \(String(format: "%.3f", match.d1)), d2: \(String(format: "%.3f", match.d2)))")
                    }
                }
            }
        }

        // 2. 각 행별 우선순위에 따른 이름 및 출처 배정
        var assignedRows: [TranscriptRow] = []
        for row in rows {
            var updated = row

            // 마이크(me) 채널은 상대방 화자 배정 대상이 아님
            guard updated.channel == .them else {
                assignedRows.append(updated)
                continue
            }

            // 수동 지정(.manual) 행은 보호
            if updated.nameSource == .manual {
                assignedRows.append(updated)
                continue
            }

            // clusterID 보정
            if updated.clusterID == nil, let diarization {
                updated.clusterID = diarization.dominantCluster(from: updated.startSeconds, to: updated.endSeconds)
            }

            // (1) Zoom 화자 태그 확인
            let zName = zoomName(updated)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let zName, !zName.isEmpty {
                updated.speakerName = zName
                updated.nameSource = .zoom
                updated.candidateNames = nil
                if let cid = updated.clusterID {
                    clusterNames[cid] = zName
                }
                assignedRows.append(updated)
                continue
            }

            // (2) 클러스터 성문 매칭 확인
            let match = updated.clusterID.flatMap { clusterMatches[$0] }
            if let match, match.confident, let person = match.person {
                updated.speakerName = person.name
                updated.nameSource = .voice
                updated.candidateNames = nil
                assignedRows.append(updated)
                continue
            }

            // 후보군 (마진 미달 제안용, 최대 2명, isMe 제외)
            let candidates: [String]?
            if let match, !match.candidates.isEmpty {
                let list = Array(match.candidates.filter { !$0.isMe }.prefix(2).map(\.name).filter { !$0.isEmpty })
                candidates = list.isEmpty ? nil : list
            } else {
                candidates = nil
            }

            // (3) 기존 슬롯 이름 확인
            if let slot = updated.speakerSlot, let slotName = existingSlotNames[slot]?.trimmingCharacters(in: .whitespacesAndNewlines), !slotName.isEmpty {
                // speakerName을 nil로 유지하여 resolveName이 speakerNames[slot]을 참조하도록 함
                updated.speakerName = nil
                updated.nameSource = .slot
                updated.candidateNames = candidates
                assignedRows.append(updated)
                continue
            }

            // (4) Zoom 폴백 이름 (1:1 회의 등)
            let fb = fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fb, !fb.isEmpty {
                updated.speakerName = fb
                updated.nameSource = .slot
                updated.candidateNames = candidates
                assignedRows.append(updated)
                continue
            }

            // (5) 슬롯 기본값 유지
            updated.speakerName = nil
            updated.nameSource = updated.nameSource ?? .slot
            updated.candidateNames = candidates
            assignedRows.append(updated)
        }

        return (assignedRows, clusterNames, log)
    }

    /// Zoom 태그 또는 수동 입력으로 확정된 클러스터별 이름 추출 (다수결 투표, 동률 시 제외).
    func confirmedNames(rows: [TranscriptRow], diarization: OfflineDiarization?) -> [String: String] {
        var clusterVotes: [String: [String: Double]] = [:]

        for row in rows {
            guard row.channel == .them else { continue }
            guard row.nameSource == .zoom || row.nameSource == .manual else { continue }
            guard let name = row.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }

            let clusterID = row.clusterID ?? diarization?.dominantCluster(from: row.startSeconds, to: row.endSeconds)
            guard let clusterID else { continue }

            let duration = max(0.1, row.endSeconds - row.startSeconds)
            clusterVotes[clusterID, default: [:]][name, default: 0] += duration
        }

        var result: [String: String] = [:]
        for (clusterID, votes) in clusterVotes {
            let sorted = votes.sorted { a, b in
                if a.value != b.value {
                    return a.value > b.value
                }
                return a.key < b.key
            }
            guard let top = sorted.first else { continue }
            if sorted.count > 1 {
                let second = sorted[1]
                if abs(top.value - second.value) < 1e-5 {
                    // 동률이면 확정 불가
                    continue
                }
            }
            result[clusterID] = top.key
        }

        return result
    }

    /// 확정된 클러스터 화자들의 세그먼트로 성문을 등록하고 충돌 시 conflict 기록.
    func enroll(
        rows: [TranscriptRow],
        diarization: OfflineDiarization,
        confirmedNames: [String: String],
        emails: [String: String] = [:],
        source: VoiceSource = .zoom
    ) -> EnrollmentReport {
        var report = EnrollmentReport()

        for (clusterID, confirmedName) in confirmedNames {
            let trimmedName = confirmedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            // them 채널 오디오는 isMe 인물로 등록하지 않음
            if let existingPerson = store.person(named: trimmedName), existingPerson.isMe {
                let msg = "[SpeakerMemory] Skipping them-channel enrollment for '\(trimmedName)' because profile belongs to user (isMe)"
                report.log.append(msg)
                continue
            }

            let matchingSegments = diarization.segments.filter { $0.clusterID == clusterID && !$0.embedding.isEmpty }
            guard !matchingSegments.isEmpty else {
                let msg = "[SpeakerMemory] No segments for cluster \(clusterID), skipping enrollment for '\(trimmedName)'"
                report.log.append(msg)
                continue
            }

            let samples = matchingSegments.map {
                EnrollmentSample(embedding: $0.embedding, quality: $0.quality, seconds: $0.duration)
            }

            // 충돌 확인: 해당 클러스터의 중심 임베딩이 다른 인물과 확신 매칭되는 경우 (isMe 제외)
            if let centroid = diarization.centroid(for: clusterID) {
                let match = store.match(centroid.embedding, excludingMe: true)
                if match.confident, let matchedPerson = match.person, !matchedPerson.isMe {
                    let isSamePerson = matchedPerson.name.caseInsensitiveCompare(trimmedName) == .orderedSame ||
                        matchedPerson.aliases.contains { $0.caseInsensitiveCompare(trimmedName) == .orderedSame }
                    if !isSamePerson {
                        let conflictMsg = "[SpeakerMemory] Conflict detected: cluster \(clusterID) matched '\(matchedPerson.name)' but confirmed as '\(trimmedName)'"
                        report.log.append(conflictMsg)
                        report.conflicts.append(matchedPerson.name)
                        do {
                            let deleted = try store.recordConflict(personID: matchedPerson.id, embedding: centroid.embedding)
                            if deleted {
                                report.log.append("[SpeakerMemory] Centroid of '\(matchedPerson.name)' removed due to conflict limit")
                            }
                        } catch {
                            let errDesc = error.localizedDescription
                            report.errors.append("Failed to record conflict for '\(matchedPerson.name)': \(errDesc)")
                            report.log.append("[SpeakerMemory] Failed to record conflict for person '\(matchedPerson.name)': \(errDesc)")
                        }
                    }
                }
            }

            // 성문 등록 실행
            let email = emails[trimmedName] ?? emails[clusterID]
            do {
                let enrolledPerson = try store.enroll(
                    name: trimmedName,
                    email: email,
                    samples: samples,
                    source: source,
                    isMe: false
                )
                let totalSecs = samples.reduce(0.0) { $0 + $1.seconds }
                report.enrolled.append(enrolledPerson.name)
                report.log.append("[SpeakerMemory] Successfully enrolled '\(enrolledPerson.name)' (\(samples.count) samples, \(String(format: "%.1f", totalSecs))s, source: \(source.rawValue))")
            } catch {
                let errDesc = error.localizedDescription
                report.errors.append("Enrollment skipped for '\(trimmedName)': \(errDesc)")
                report.log.append("[SpeakerMemory] Enrollment skipped for '\(trimmedName)': \(errDesc)")
            }
        }

        return report
    }

    /// 마이크(me) 채널 오디오 샘플로 본인 성문 등록.
    @discardableResult
    func enrollMe(micWAVEmbeddings: [EnrollmentSample], myName: String) throws -> Person {
        let trimmedName = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try store.enroll(
            name: trimmedName.isEmpty ? "Me" : trimmedName,
            email: nil,
            samples: micWAVEmbeddings,
            source: .live,
            isMe: true
        )
    }

    /// 저장된 회의 행들에서 대상 행과 일치하는 화자의 이름과 출처(.manual)를 갱신하는 순수 함수.
    /// 대상 행과 동일한 슬롯, 동일한 클러스터 ID, 또는 동일한 id를 가진 행들의 speakerName과 nameSource를 .manual로 설정하고 candidateNames를 nil로 초기화.
    static func rewriteSavedSpeakerRows(
        rows: [TranscriptRow],
        target: TranscriptRow,
        name: String
    ) -> [TranscriptRow] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }

        var updated = rows
        for i in 0..<updated.count {
            if target.channel == .me {
                if updated[i].channel == .me {
                    updated[i].speakerName = trimmed
                    updated[i].nameSource = .manual
                    updated[i].candidateNames = nil
                }
            } else {
                guard updated[i].channel == .them else { continue }
                let matchesSlot = (target.speakerSlot != nil && updated[i].speakerSlot == target.speakerSlot)
                let matchesCluster = (target.clusterID != nil && updated[i].clusterID == target.clusterID)
                let matchesID = (updated[i].id == target.id)

                if matchesSlot || matchesCluster || matchesID {
                    updated[i].speakerName = trimmed
                    updated[i].nameSource = .manual
                    updated[i].candidateNames = nil
                }
            }
        }
        return updated
    }
}
