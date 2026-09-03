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
    /// "Start LiveNote only" 선택 시 호출: 링크는 열지 않고 기록만 시작.
    @ObservationIgnored var onRecordRequested: (() -> Void)?
    /// "Change notification settings" 선택 시 호출: AppState가 Settings 화면을 요청.
    @ObservationIgnored var onOpenSettingsRequested: (() -> Void)?
    /// 캘린더 회의 시작 시각 도달 시 호출 (해당 일정 전달).
    /// 반환값은 "실제로 처리했는지"다. AppState가 autoStartAtCalendarTime 꺼짐·이미 기록 중 등으로
    /// 무시하면 false를 돌려주고, 그때는 통지 키를 남기지 않아 다음 tick에 다시 시도한다.
    @ObservationIgnored var onMeetingTimeReached: ((UpcomingMeetingItem) -> Bool)?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var alertedKeys: Set<String> = []
    /// 시작 시각 도달을 이미 통지한 일정 (회의당 1회). 값은 회의 종료 시각이고, 지난 일정은 tick에서 버린다.
    @ObservationIgnored private var startNotifiedKeys: [String: Date] = [:]
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
                issueMessage = "Calendar access denied — meeting alerts are off. Allow full access for LiveNote in System Settings > Privacy & Security > Calendars."
            }
        default:
            issueMessage = "No calendar access — meeting alerts are disabled. Allow full access for LiveNote in System Settings > Privacy & Security > Calendars."
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

        // 사이드바 "오늘 일정" 갱신 (내부 60초 스로틀)
        refreshTodayUpcoming(now: now)

        // 종료된 회의의 통지 키 정리 (앱을 오래 켜둬도 집합이 계속 커지지 않게)
        startNotifiedKeys = Self.prunedNotifiedKeys(startNotifiedKeys, now: now)

        // 회의 시작 시각 도달 통지 (AppState의 autoStartAtCalendarTime이 실제 시작 여부 결정)
        notifyMeetingTimeReached(now: now)

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
            suggestedAgenda: nil,
            onJoin: { [weak self] in
                Task { @MainActor in self?.join() }
            },
            onJoinOnly: { [weak self] in
                Task { @MainActor in self?.joinOnly() }
            },
            onRecordOnly: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.onRecordRequested?()
                    self.dismissAlert()
                }
            },
            onOpenSettings: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.onOpenSettingsRequested?()
                    self.dismissAlert()
                }
            },
            onDismiss: { [weak self] in
                Task { @MainActor in self?.dismissAlert() }
            }
        )
    }

    /// 오늘 일정 중 시작 시각을 막 지난 온라인 회의를 한 번씩 통지한다.
    /// 폴링 주기(10초)와 todayUpcoming 갱신 주기(60초)를 감안해 시작 후 3분까지 유효.
    private func notifyMeetingTimeReached(now: Date) {
        guard let handler = onMeetingTimeReached else { return }
        for item in todayUpcoming {
            guard item.webLink != nil else { continue }
            guard now >= item.start, now <= item.start.addingTimeInterval(3 * 60) else { continue }
            guard startNotifiedKeys[item.id] == nil else { continue }
            // 수신 측이 무시한 통지는 소비하지 않는다: 설정이 켜지거나 기록이 끝나면 다시 시도한다.
            guard handler(item) else { continue }
            startNotifiedKeys[item.id] = item.end
            return
        }
    }

    /// 이미 끝난 회의의 통지 키를 버린다.
    static func prunedNotifiedKeys(_ keys: [String: Date], now: Date) -> [String: Date] {
        keys.filter { $0.value >= now }
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
                title: event.title ?? "Meeting",
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
        openCurrentMeetingLink()
        onJoinRequested?()
        dismissAlert()
    }

    /// 회의 링크만 열고 기록은 시작하지 않는다 ("Join meeting only").
    private func joinOnly() {
        openCurrentMeetingLink()
        dismissAlert()
    }

    private func openCurrentMeetingLink() {
        guard let meeting = currentAlert else { return }
        // Zoom 앱이 설치되어 있으면 딥링크로 직접 실행, 아니면 웹 링크 (브라우저 → Zoom 리다이렉트)
        let zoomInstalled = URL(string: "zoommtg://")
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
        let target = (zoomInstalled ? meeting.deepLink : nil) ?? meeting.webLink
        NSWorkspace.shared.open(target)
    }

    private func dismissAlert() {
        panel.close()
        currentAlert = nil
    }

    // MARK: - 오늘 일정 (사이드바 "다가오는 회의" + Start now)

    struct UpcomingMeetingItem: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let webLink: URL?
        let deepLink: URL?

        /// 지금 시작 버튼 활성 조건: 시작 10분 전 ~ 종료 전
        func isNow(_ now: Date = Date()) -> Bool {
            now >= start.addingTimeInterval(-10 * 60) && now <= end
        }
    }

    /// 오늘 남은 일정 (60초마다 갱신, 최대 6개)
    private(set) var todayUpcoming: [UpcomingMeetingItem] = []
    @ObservationIgnored private var lastUpcomingRefresh = Date.distantPast

    private func refreshTodayUpcoming(now: Date) {
        guard now.timeIntervalSince(lastUpcomingRefresh) >= 60 else { return }
        lastUpcomingRefresh = now
        let endOfDay = Foundation.Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-15 * 60), end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { event in
                guard let start = event.startDate, let end = event.endDate,
                      !event.isAllDay, event.status != .canceled, end > now else { return false }
                if let attendees = event.attendees,
                   let me = attendees.first(where: { $0.isCurrentUser }),
                   me.participantStatus == .declined { return false }
                _ = start
                return true
            }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

        var seen = Set<String>()
        var items: [UpcomingMeetingItem] = []
        for event in events {
            guard let start = event.startDate, let end = event.endDate else { continue }
            let key = "\(event.eventIdentifier ?? event.title ?? "?")@\(Int(start.timeIntervalSince1970))"
            guard seen.insert(key).inserted else { continue }
            let web = Self.firstZoomLink(in: [event.url?.absoluteString, event.location, event.notes])
            items.append(UpcomingMeetingItem(
                id: key,
                title: event.title ?? "Meeting",
                start: start,
                end: end,
                webLink: web,
                deepLink: web.flatMap(Self.zoomDeepLink(for:))
            ))
            if items.count >= 6 { break }
        }
        todayUpcoming = items
    }

    /// 지금 진행 중(시작 10분 전~종료)인 일정 하나를 골라 제목과 참석자를 함께 반환한다.
    /// 제목과 참석자가 서로 다른 일정에서 섞이지 않도록 선택을 한 곳으로 모은 진입점이다.
    /// 선택 규칙: 온라인 회의 링크가 있는 첫 일정, 없으면 첫 일정.
    func ongoingMeetingContext(now: Date = Date()) -> (title: String?, attendees: [Attendee]) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return (nil, []) }
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
        let withLink = ongoing.first {
            Self.firstZoomLink(in: [$0.url?.absoluteString, $0.location, $0.notes]) != nil
        }
        guard let event = withLink ?? ongoing.first else { return (nil, []) }

        let raw = (event.attendees ?? [])
            .filter { $0.participantType == .person && !$0.isCurrentUser }
            .map { (name: $0.name, email: Self.email(fromParticipantURL: $0.url)) }
        return (event.title, Self.normalizedAttendees(from: raw))
    }

    /// 지금 진행 중(시작 10분 전~종료)인 일정의 제목. 온라인 회의 링크가 있는 일정 우선.
    func ongoingMeetingTitle(now: Date = Date()) -> String? {
        ongoingMeetingContext(now: now).title
    }

    // MARK: - 참석자 이름 후보 (화자 rename 원클릭용)

    /// 지금 진행 중이거나 10분 내 시작하는 일정의 참석자 이름 목록.
    /// 화자 칩 rename 팝오버에 원클릭 후보로 표시됨. 본인·회의실 리소스 제외, 최대 10명.
    func attendeeNamesForOngoingMeeting(now: Date = Date()) -> [String] {
        ongoingMeetingAttendees(now: now).map(\.name)
    }

    /// 제목과 같은 일정에서 뽑은 참석자 (이름 + 이메일).
    /// 회의 저장(session.json)과 이후 브리핑·담당자 매칭이 쓰는 원본 데이터다.
    func ongoingMeetingAttendees(now: Date = Date()) -> [Attendee] {
        ongoingMeetingContext(now: now).attendees
    }

    /// 캘린더 참석자 원본(표시 이름, 이메일)을 저장용 Attendee로 정규화한다.
    /// 중복 판정 키는 이메일(소문자) 우선, 없을 때만 이름이다. 이렇게 해야 동명이인을 잃지 않는다.
    /// 이름이 비어도 이메일이 있으면 이메일에서 이름을 만들어 살린다.
    static func normalizedAttendees(
        from raw: [(name: String?, email: String?)],
        limit: Int = 10
    ) -> [Attendee] {
        var seen = Set<String>()
        var attendees: [Attendee] = []
        for participant in raw {
            let rawEmail = participant.email?.trimmingCharacters(in: .whitespaces)
            let email = (rawEmail?.isEmpty == false) ? rawEmail : nil
            var name = prettyName(participant.name ?? "")
            if name.isEmpty, let email {
                name = prettyName(email)
            }
            guard !name.isEmpty else { continue }
            let key = email?.lowercased() ?? name.lowercased()
            guard seen.insert(key).inserted else { continue }
            attendees.append(Attendee(name: name, email: email))
            if attendees.count >= limit { break }
        }
        return attendees
    }

    /// EKParticipant.url에서 이메일 주소 추출 ("mailto:jane@x.com" → "jane@x.com").
    /// mailto가 아니거나 주소가 비면 nil.
    static func email(fromParticipantURL url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        var rest = url.absoluteString
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        rest = String(rest[rest.index(after: colon)...])
        // 헤더 파라미터("?subject=…")와 다중 수신자는 버리고 첫 주소만 쓴다.
        if let question = rest.firstIndex(of: "?") { rest = String(rest[..<question]) }
        if let comma = rest.firstIndex(of: ",") { rest = String(rest[..<comma]) }
        let address = (rest.removingPercentEncoding ?? rest).trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : address
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
    /// 온라인 회의 링크 탐지 — Zoom 우선, 이어서 Teams / Google Meet / Webex (2026-09-01 확장).
    /// 패턴 순서 = 우선순위: 초대문에 여러 링크가 섞여 있으면 앞선 플랫폼을 택한다.
    static func firstZoomLink(in texts: [String?]) -> URL? {
        let patterns = [
            "https://[A-Za-z0-9.-]*zoom\\.us/[^\\s<>\"'\\)\\]]+",
            "https://teams\\.microsoft\\.com/l/meetup-join/[^\\s<>\"'\\)\\]]+",
            "https://teams\\.live\\.com/meet/[^\\s<>\"'\\)\\]]+",
            "https://meet\\.google\\.com/[^\\s<>\"'\\)\\]]+",
            "https://[A-Za-z0-9.-]*webex\\.com/[^\\s<>\"'\\)\\]]+",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
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
