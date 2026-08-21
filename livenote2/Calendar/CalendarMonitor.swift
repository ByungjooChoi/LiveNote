import AppKit
import EventKit
import Foundation
import Observation

/// 회의 임박 알림 대상 하나.
struct MeetingAlert: Equatable {
    /// eventIdentifier + 시작시각. 같은 회의를 두 번 알리지 않기 위한 키.
    let key: String
    let title: String
    let start: Date
    let end: Date
    /// 초대에 들어 있던 원본 https 링크 (브라우저 폴백용)
    let webLink: URL
    /// zoommtg:// 딥링크 (파싱 성공 시 — Zoom 앱을 브라우저 없이 바로 실행)
    let deepLink: URL?
}

/// 애플 캘린더 연동 — 회의 시작 1분 전 참가 팝업 (Granola 스타일).
///
/// EventKit으로 Calendar.app에 연결된 모든 캘린더(구글 계정 포함)를 10초 주기로 확인해
/// Zoom 링크가 있는 일정을 찾고, 시작 60초 전부터 우상단에 플로팅 패널을 띄웁니다.
/// [참가]: zoommtg:// 딥링크로 Zoom 앱을 직접 열고(미설치 시 웹 링크),
/// 기록이 꺼져 있으면 전사도 함께 시작합니다 (onJoinRequested — AppState가 배선).
///
/// 제외: 종일 일정, 취소된 일정, 내가 거절한 초대, Zoom 링크가 없는 일정.
/// 시작 후 10분까지는 팝업을 유지합니다 (지각 참가 대비).
@MainActor
@Observable
final class CalendarMonitor {

    /// 회의 임박 알림 사용 여부 (UserDefaults 영속, 기본 켜짐 — 최초 켤 때 캘린더 권한 요청)
    private(set) var isEnabled = false
    /// 권한 거부 등 안내 배너 (nil이면 정상)
    var issueMessage: String?

    /// [참가] 클릭 시 호출 — AppState가 "기록 시작"을 배선합니다.
    @ObservationIgnored var onJoinRequested: (() -> Void)?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var alertedKeys: Set<String> = []
    @ObservationIgnored private var currentAlert: MeetingAlert?
    @ObservationIgnored private let panel = MeetingAlertPanelController()

    /// 시작 몇 초 전부터 팝업을 띄울지
    private static let leadSeconds: TimeInterval = 60
    /// 시작 후 이 시간까지 팝업 유지 (늦게 봐도 참가할 수 있게)
    private static let graceSeconds: TimeInterval = 10 * 60
    /// 폴링 주기 (근처 일정 조회는 로컬 DB라 저렴)
    private static let pollNanoseconds: UInt64 = 10_000_000_000

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "calendarAlerts") != nil {
            isEnabled = defaults.bool(forKey: "calendarAlerts")
        } else {
            isEnabled = true
        }
        if isEnabled {
            Task { await ensureAccessAndStart() }
        }
    }

    // MARK: - 설정

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: "calendarAlerts")
        if on {
            Task { await ensureAccessAndStart() }
        } else {
            monitorTask?.cancel()
            monitorTask = nil
            dismissAlert()
            issueMessage = nil
        }
    }

    private func ensureAccessAndStart() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            issueMessage = nil
            startMonitoring()
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            if granted {
                issueMessage = nil
                startMonitoring()
            } else {
                issueMessage = "캘린더 접근이 거부되어 회의 참가 알림이 꺼져 있습니다. 시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 livenote2에 전체 접근을 허용해 주세요."
            }
        default:
            issueMessage = "캘린더 접근 권한이 없어 회의 참가 알림이 동작하지 않습니다. 시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 livenote2에 전체 접근을 허용해 주세요."
        }
    }

    // MARK: - 감시 루프

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
            }
        }
    }

    private func tick() {
        guard isEnabled else { return }
        let now = Date()

        // 떠 있는 팝업이 유예 시간을 넘기면 자동 닫기
        if let current = currentAlert, now > current.start.addingTimeInterval(Self.graceSeconds) {
            dismissAlert()
        }
        // 팝업이 이미 떠 있으면 새로 띄우지 않음
        guard currentAlert == nil else { return }

        guard let candidate = nextEligibleMeeting(at: now) else { return }
        alertedKeys.insert(candidate.key)
        currentAlert = candidate
        panel.show(
            meeting: candidate,
            onJoin: { [weak self] in
                Task { @MainActor in self?.join() }
            },
            onDismiss: { [weak self] in
                Task { @MainActor in self?.dismissAlert() }
            }
        )
    }

    /// 지금 알림을 띄워야 할 가장 가까운 회의.
    private func nextEligibleMeeting(at now: Date) -> MeetingAlert? {
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.graceSeconds),
            end: now.addingTimeInterval(30 * 60),
            calendars: nil
        )
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

        for event in events {
            guard let start = event.startDate else { continue }
            // 알림 창: 시작 60초 전 ~ 시작 후 10분
            guard now >= start.addingTimeInterval(-Self.leadSeconds),
                  now <= start.addingTimeInterval(Self.graceSeconds) else { continue }

            // 내가 거절한 초대는 제외
            if let attendees = event.attendees,
               let me = attendees.first(where: { $0.isCurrentUser }),
               me.participantStatus == .declined { continue }

            guard let webLink = Self.firstZoomLink(
                in: [event.url?.absoluteString, event.location, event.notes]
            ) else { continue }

            let key = "\(event.eventIdentifier ?? event.title ?? "?")@\(Int(start.timeIntervalSince1970))"
            guard !alertedKeys.contains(key) else { continue }

            return MeetingAlert(
                key: key,
                title: event.title ?? "회의",
                start: start,
                end: event.endDate ?? start.addingTimeInterval(30 * 60),
                webLink: webLink,
                deepLink: Self.zoomDeepLink(for: webLink)
            )
        }
        return nil
    }

    // MARK: - 참가 / 닫기

    private func join() {
        guard let meeting = currentAlert else { return }
        // Zoom 앱이 설치되어 있으면 딥링크로 직접 실행, 아니면 웹 링크 (브라우저 → Zoom 리다이렉트)
        let zoomInstalled = URL(string: "zoommtg://")
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        let target = (zoomInstalled ? meeting.deepLink : nil) ?? meeting.webLink
        NSWorkspace.shared.open(target)
        onJoinRequested?()
        dismissAlert()
    }

    private func dismissAlert() {
        panel.close()
        currentAlert = nil
    }

    // MARK: - 참석자 이름 후보 (화자 rename 원클릭용)

    /// 지금 진행 중이거나 10분 내 시작하는 일정의 참석자 이름 목록.
    /// 화자 칩 rename 팝오버에 원클릭 후보로 표시됨. 본인·회의실 리소스 제외, 최대 10명.
    func attendeeNamesForOngoingMeeting(now: Date = Date()) -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-90 * 60),
            end: now.addingTimeInterval(30 * 60),
            calendars: nil
        )
        let ongoing = store.events(matching: predicate).filter { event in
            guard let start = event.startDate, let end = event.endDate, !event.isAllDay,
                  event.status != .canceled else { return false }
            return now >= start.addingTimeInterval(-10 * 60) && now <= end
        }
        var seen = Set<String>()
        var names: [String] = []
        for event in ongoing {
            for attendee in event.attendees ?? [] {
                guard attendee.participantType == .person, !attendee.isCurrentUser else { continue }
                let name = Self.prettyName(attendee.name ?? "")
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                names.append(name)
                if names.count >= 10 { return names }
            }
        }
        return names
    }

    /// 표시 이름이 이메일이면 로컬 파트를 사람 이름처럼 정리 ("jane.doe@x.com" → "Jane Doe").
    static func prettyName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@") else { return trimmed }
        let local = trimmed.split(separator: "@").first.map(String.init) ?? trimmed
        return local.split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Zoom 링크 파싱

    /// 여러 텍스트 필드(url/location/notes)에서 첫 Zoom 링크를 찾음.
    static func firstZoomLink(in texts: [String?]) -> URL? {
        let pattern = "https://[A-Za-z0-9.-]*zoom\\.us/[^\\s<>\"'\\)\\]]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        for text in texts {
            guard let text, !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let matchRange = Range(match.range, in: text),
               let url = URL(string: String(text[matchRange])) {
                return url
            }
        }
        return nil
    }

    /// https://{host}.zoom.us/j/{회의번호}?pwd=... → zoommtg://{host}/join?action=join&confno=...&pwd=...
    /// 회의번호를 못 찾으면(개인 링크 /my/ 등) nil — 웹 링크로 폴백.
    static func zoomDeepLink(for webLink: URL) -> URL? {
        guard let components = URLComponents(url: webLink, resolvingAgainstBaseURL: false),
              let host = components.host else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let jIndex = parts.firstIndex(of: "j"), jIndex + 1 < parts.count else { return nil }
        let confno = parts[jIndex + 1].filter(\.isNumber)
        guard !confno.isEmpty else { return nil }

        var deep = URLComponents()
        deep.scheme = "zoommtg"
        deep.host = host
        deep.path = "/join"
        var items = [
            URLQueryItem(name: "action", value: "join"),
            URLQueryItem(name: "confno", value: confno),
        ]
        if let pwd = components.queryItems?.first(where: { $0.name == "pwd" })?.value {
            items.append(URLQueryItem(name: "pwd", value: pwd))
        }
        deep.queryItems = items
        return deep.url
    }
}
