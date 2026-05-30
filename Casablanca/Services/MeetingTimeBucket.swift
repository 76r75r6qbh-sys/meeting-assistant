import Foundation

enum MeetingTimeBucket: String, CaseIterable {
    case upcoming, today, thisWeek, thisMonth, thisYear, earlier

    var title: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .thisYear: return "This Year"
        case .earlier: return "Earlier"
        }
    }

    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> MeetingTimeBucket {
        if date > now { return .upcoming }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .thisMonth }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return .thisYear }
        return .earlier
    }
}
