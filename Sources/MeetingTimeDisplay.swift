import Foundation

enum MeetingTimeDisplay {
    /// Wall-clock meeting times; audio offsets continue to describe only captured samples.
    static func interval(start source: String, end: Date?, legacyDuration: Double = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = source.split(separator: " ").last.flatMap { TimeZone(abbreviation: String($0)) } ?? .current
        var start: Date?
        for format in ["yyyy-MM-dd HH:mm:ss zzz", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: source) { start = parsed; break }
        }
        // Date-only legacy records retain their known precision.
        guard let start else { return source }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        func floorTen(_ date: Date) -> Date {
            let minute = calendar.dateInterval(of: .minute, for: date)!.start
            return calendar.date(byAdding: .minute, value: -(calendar.component(.minute, from: minute) % 10), to: minute)!
        }
        let roundedStart = floorTen(start)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let startText = formatter.string(from: roundedStart)
        let legacyEnd = legacyDuration.isFinite && legacyDuration > 0 ? start.addingTimeInterval(legacyDuration) : nil
        guard let end = end ?? legacyEnd else { return startText }
        let actualEnd = max(start, end)
        let floorEnd = floorTen(actualEnd)
        let roundedEnd = actualEnd > floorEnd ? calendar.date(byAdding: .minute, value: 10, to: floorEnd)! : floorEnd
        formatter.dateFormat = calendar.isDate(roundedStart, inSameDayAs: roundedEnd) ? "HH:mm" : "yyyy-MM-dd HH:mm"
        return startText + "~" + formatter.string(from: roundedEnd)
    }
}
