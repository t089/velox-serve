#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#else
    #error("Unsupported")
#endif

public struct UTCInstant {
    var timespec: timespec

    public var components: (seconds: Int, nanoseconds: Int) {
        return (timespec.tv_sec, timespec.tv_nsec)
    }

    public static var now: UTCInstant {
        #if canImport(Darwin)
        var ts: timespec = Darwin.timespec()
        #elseif canImport(Glibc)
        var ts: timespec = Glibc.timespec()
        #else
        #error("Unsupported")
        #endif
        clock_gettime(CLOCK_REALTIME, &ts)
        return UTCInstant(timespec: ts)
    }

    public func formatted() -> String {
        var now = self.timespec.tv_sec

        var components = tm()

        gmtime_r(&now, &components)

        let year: Int = numericCast(components.tm_year) + 1900
        let month: Int = numericCast(components.tm_mon)  // 0-11
        let day: Int = numericCast(components.tm_mday)  // 1-31
        let wday: Int = numericCast(components.tm_wday)  // 0-6 [Sun - Sat]

        let hour: Int = numericCast(components.tm_hour)  // 0-23
        let minute: Int = numericCast(components.tm_min)  // 0-59
        let sec: Int = numericCast(components.tm_sec)  // 0-59

        return
            "\(days[wday]), \(numbers[day]) \(months[month]) \(year) \(numbers[hour]):\(numbers[minute]):\(numbers[sec]) GMT"
    }
}

private let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let months = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]
private let numbers = [
    "00", "01", "02", "03", "04", "05", "06", "07", "08", "09",
    "10", "11", "12", "13", "14", "15", "16", "17", "18", "19",
    "20", "21", "22", "23", "24", "25", "26", "27", "28", "29",
    "30", "31", "32", "33", "34", "35", "36", "37", "38", "39",
    "40", "41", "42", "43", "44", "45", "46", "47", "48", "49",
    "50", "51", "52", "53", "54", "55", "56", "57", "58", "59",
    "60", "61", "62", "63", "64", "65", "66", "67", "68", "69",
    "70", "71", "72", "73", "74", "75", "76", "77", "78", "79",
    "80", "81", "82", "83", "84", "85", "86", "87", "88", "89",
    "90", "91", "92", "93", "94", "95", "96", "97", "98", "99",
]
