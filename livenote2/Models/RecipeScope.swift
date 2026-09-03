import Foundation

/// 레시피 실행 범위. 회의 목록 메타데이터(startedAt, url)만으로 필터한다.
enum RecipeScope: Equatable, Sendable {
    case thisWeek
    case lastDays(Int)
    case currentMeeting(URL)
    case manual([URL])

    var label: String {
        switch self {
        case .thisWeek:
            return "This week"
        case .lastDays(let n):
            return "Last \(n) days"
        case .currentMeeting:
            return "This meeting"
        case .manual(let urls):
            return urls.count == 1 ? "1 meeting" : "\(urls.count) meetings"
        }
    }

    /// 레시피 기본 범위를 실행 시점 범위로 변환한다.
    /// `.currentMeeting`인데 열린 회의가 없으면 빈 수동 선택으로 시작한다(다른 범위로 바꿔치기하지 않는다).
    /// `.manual`도 빈 선택으로 시작해 사용자가 시트에서 고르게 한다.
    init(default scopeDefault: RecipeScopeDefault, currentMeeting: URL?) {
        switch scopeDefault {
        case .thisWeek:
            self = .thisWeek
        case .lastDays(let days):
            self = .lastDays(days)
        case .currentMeeting:
            if let url = currentMeeting {
                self = .currentMeeting(url)
            } else {
                self = .manual([])
            }
        case .manual:
            self = .manual([])
        }
    }

    /// 주 시작은 월요일 00:00(로컬), Calendar.current.firstWeekday와 무관.
    static func weekStart(for now: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2  // Monday
        let startOfToday = cal.startOfDay(for: now)
        // Calendar.component(.weekday, ...)는 firstWeekday 설정과 무관하게
        // 1=Sunday...7=Saturday 고정값을 반환한다.
        let weekday = cal.component(.weekday, from: startOfToday)
        // Monday(2) 기준 오늘까지 며칠 지났는지.
        let daysSinceMonday = (weekday - 2 + 7) % 7
        return cal.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday) ?? startOfToday
    }

    /// 순수 함수. 결과는 startedAt 내림차순(최신 먼저).
    func resolve(meetings: [MeetingSummary], now: Date = Date(), calendar: Calendar = .current) -> [MeetingSummary] {
        switch self {
        case .thisWeek:
            let start = RecipeScope.weekStart(for: now, calendar: calendar)
            return meetings
                .filter { $0.startedAt >= start && $0.startedAt <= now }
                .sorted { $0.startedAt > $1.startedAt }

        case .lastDays(let n):
            let start = calendar.date(byAdding: .day, value: -n, to: now) ?? now
            return meetings
                .filter { $0.startedAt >= start && $0.startedAt <= now }
                .sorted { $0.startedAt > $1.startedAt }

        case .currentMeeting(let url):
            let target = url.standardizedFileURL.path
            return meetings
                .filter { $0.url.standardizedFileURL.path == target }
                .sorted { $0.startedAt > $1.startedAt }

        case .manual(let urls):
            let targets = Set(urls.map { $0.standardizedFileURL.path })
            return meetings
                .filter { targets.contains($0.url.standardizedFileURL.path) }
                .sorted { $0.startedAt > $1.startedAt }
        }
    }
}
