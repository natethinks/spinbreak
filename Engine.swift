// SpinBreak activity engine. Foundation only, so it can be tested headless (tests/main.swift).
//
// How a break gets picked:
// 1. Filter: time window, daylight, per-item max/gap, group caps (exercise, vigorous, screens,
//    caffeine, cleaning), category caps, weekly caps, posture, and no play twice in a row.
// 2. Anchors win: daily backbone items (sunrise walk, meals, wind-down) are forced
//    when their slot comes up. "next" chains (lunch -> walk, cook -> eat) are forced too.
// 3. Otherwise a weighted lottery: base weight x category deficit (how behind today's target you
//    are for this time of day) x recency (avoid same category back-to-back) x soft time boosts.
// 4. If nothing passes, relax the soft rules step by step, so the draw is never empty.
import Foundation

struct Activity: Codable, Hashable, Identifiable {
    var id: String
    var emoji: String
    var name: String
    var category: String
    var how: String
    var maxPerDay: Int = 1
    var minGap: Int? = nil            // minutes between repeats of this item
    var from: Double = 8              // earliest start hour (local, fractional ok)
    var to: Double = 22               // latest start hour (exclusive)
    var weight: Double = 3
    var groups: [String]? = nil       // ex, vig, screen, caff, clean
    var anchor: String? = nil         // "first" or "HH:MM-HH:MM"
    var soft: String? = nil           // "HH:MM-HH:MM", weight x4 inside
    var next: String? = nil           // forced right after this item id
    var daylight: Bool? = nil         // must start by sunset - 25 min
    var notFirst: Bool? = nil
    var seated: Bool? = nil
    var weeklyMax: Int? = nil
    var months: [Int]? = nil          // only these months (1-12)
    var endsDay: Bool? = nil          // once done, only `afterDay` items are offered
    var afterDay: Bool? = nil         // only offered after the day has ended
    var days: [Int]? = nil            // only these weekdays (Calendar: 1 = Sun … 7 = Sat)
    var off: Bool? = nil              // switched off in Settings: never offered

    var title: String { "\(emoji) \(name)" }
}

struct GroupRule: Codable, Hashable { var cap: Int; var gap: Int? = nil }
struct CategoryRule: Codable, Hashable { var target: Int; var cap: Int }

struct Catalog: Codable {
    var latitude: Double = 40.0        // home, for sunrise and sunset (Settings › Schedule looks your town up)
    var longitude: Double = -100.0
    /// Terrain horizon around the house: degrees of elevation blocked, every 5° of azimuth from north.
    /// Lets a mountain delay your sunrise. nil = flat horizon.
    var horizon: [Double]? = nil
    var dayStart: Double = 8
    var dayEnd: Double = 22
    var groups: [String: GroupRule]
    var categories: [String: CategoryRule]
    var activities: [Activity]
    var checklist: [String]? = nil     // the morning gate; nil = Engine.morningChecklist
}

struct Done: Codable, Hashable {
    var id: String
    var category: String
    var at: Date
    var completed: Bool?
    var note: String? = nil
    var skipped: Bool? = nil
    var mins: Double? = nil           // how long it actually took (finished early, or the full block)
    var mess: Int? = nil              // chores: how bad it was before you started (1 fine, 2 meh, 3 rough)
}

struct Draw {
    var pick: Activity
    var pool: [Activity]       // other eligible options (for showing on the wheel)
    var anchored: Bool
}

enum Engine {
    // MARK: draw

    /// `household`: rooms someone else in the house cleaned or is cleaning (shared calendar), already mapped to
    /// this catalog's room ids. They only feed room rules: mess, weekly caps, "taken today". Never capacity or targets.
    static func draw(_ c: Catalog, history: [Done], now: Date = Date(), avoid: String? = nil,
                     reroll: Bool = false, calendar cal: Calendar = .current, household: [Done] = [],
                     rng: inout some RandomNumberGenerator) -> Draw {
        let today = history.filter { $0.skipped != true && cal.isDate($0.at, inSameDayAs: now) }.sorted { $0.at.timeIntervalSinceReferenceDate < $1.at.timeIntervalSinceReferenceDate }
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let houseDone = household.filter { $0.completed == true && $0.at.timeIntervalSinceReferenceDate <= now.timeIntervalSinceReferenceDate }
        let week = (history + houseDone).filter { $0.at.timeIntervalSinceReferenceDate > weekAgo.timeIntervalSinceReferenceDate }
        let byId = Dictionary(c.activities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hour = hourOf(now, cal)
        let sun = sunOnHouse(on: now, c, cal)
        let sunsetH = sun.set, sunriseH = sun.rise
        let month = cal.component(.month, from: now)
        let weekday = cal.component(.weekday, from: now)

        // Full-history facts, computed once: the latest completed entry per item, and which
        // clean-* rooms have never been done (we still need to learn how bad they are).
        let latest = latestCompleted(history + houseDone)
        // Someone else took a room today (done, or on it right now): it's theirs. Rooms they're on right now
        // make the other rooms more likely, so you end up cleaning at the same time, in different rooms.
        let houseToday = household.filter { cal.isDate($0.at, inSameDayAs: now) }
        let partnerCleaning = household.contains { $0.note == "live" }
        let unsurveyed = Set(c.activities.filter { isRoom($0) && latest[$0.id] == nil }.map(\.id))
        let outdoorMins = outdoorMinutes(history: history, now: now, cal: cal)
        let weekPos = (weekday + 5) % 7          // 0 = Monday … 6 = Sunday

        // "Already did it" taps: that item is off the table for today (and for the week, if it's a weekly one).
        let already = history.filter { $0.note == "already done" }
        let blocked = Set(already.filter { cal.isDate($0.at, inSameDayAs: now) }.map(\.id))
            .union(already.filter { d in
                guard let a = byId[d.id], a.weeklyMax != nil else { return false }
                return d.at.timeIntervalSinceReferenceDate > weekWindowStart(a, now: now, cal: cal).timeIntervalSinceReferenceDate
            }.map(\.id))
            .union(houseToday.map(\.id))

        // Strictness levels: 0 = all rules; 1 = drop posture/recency/gaps; 2 = drop time windows (not safety); 3 = anything with daily room.
        for level in 0...3 {
            let ok = c.activities.filter { a in
                a.id != avoid && !blocked.contains(a.id) && eligible(a, c, today, week, byId, now: now, hour: hour, sunsetH: sunsetH,
                                          month: month, level: level, reroll: reroll, sunriseH: sunriseH,
                                          latest: latest, weekday: weekday, cal: cal)
            }
            if ok.isEmpty { continue }

            if !reroll && level == 0 {
                // "next" chains first, then anchors whose slot is now.
                if let last = today.last, let chained = ok.first(where: { $0.next == last.id }) {
                    return Draw(pick: chained, pool: ok, anchored: true)
                }
                let due = ok.filter { a in
                    guard let an = a.anchor else { return false }
                    if an == "first" { return today.isEmpty }
                    if an == "sun" { return hour >= sunriseH && hour < sunriseH + 2.5 }
                    guard let span = parseSpan(an) else { return false }
                    return hour >= span.0 && hour < span.1
                }
                if let a = due.min(by: { (parseSpan($0.anchor!)?.1 ?? -1) < (parseSpan($1.anchor!)?.1 ?? -1) }) {
                    return Draw(pick: a, pool: ok, anchored: true)
                }
            }

            // Weighted lottery.
            let f = max(0, min(1, (hour - c.dayStart) / max(1, c.dayEnd - c.dayStart)))
            let lastCats = today.suffix(2).map(\.category)
            let weights: [Double] = ok.map { a in
                var w = max(0.01, a.weight)
                if let rule = c.categories[a.category] {
                    let done = Double(today.filter { $0.category == a.category }.count)
                    // Survey phase: while any room is unseen, home pulls one extra break a day (caps unchanged).
                    let target = rule.target + (a.category == "home" && !unsurveyed.isEmpty ? 1 : 0)
                    let expected = Double(target) * f
                    if done > expected + 1 { w *= 0.7 }
                    else { w *= min(4, max(1, 1 + 1.5 * max(0, expected - done))) }
                }
                if level == 0 {
                    if lastCats.count == 2 && lastCats.allSatisfy({ $0 == a.category }) { w *= 0.2 }
                    else if lastCats.last == a.category { w *= 0.4 }
                }
                if let s = a.soft.flatMap(parseSpan), hour >= s.0 && hour < s.1 { w *= 4 }
                if a.soft == "sunset", hour >= sunsetH - 0.75 { w *= 4 }
                if isRoom(a) {
                    if unsurveyed.contains(a.id) { w *= 6 }
                    else if latest[a.id]?.mess == 3 { w *= 3 }
                    else if latest[a.id]?.mess == 2 { w *= 1.5 }
                    if partnerCleaning { w *= 2.5 }
                }
                // Nature counter: aim for 120 outdoor minutes a week; push harder late in a thin week.
                if a.category == "outdoors" && outdoorMins < 120 {
                    w *= (outdoorMins < 60 && hour >= 12 && weekPos >= 3) ? 2 : 1.5
                }
                return w
            }
            let total = weights.reduce(0, +)
            var r = Double.random(in: 0..<total, using: &rng)
            for (a, w) in zip(ok, weights) {
                r -= w
                if r < 0 { return Draw(pick: a, pool: ok, anchored: false) }
            }
            return Draw(pick: ok[ok.count - 1], pool: ok, anchored: false)
        }
        return Draw(pick: freeChoice, pool: [freeChoice], anchored: false)
    }

    static func draw(_ c: Catalog, history: [Done], now: Date = Date(), avoid: String? = nil, reroll: Bool = false, household: [Done] = []) -> Draw {
        var g = SystemRandomNumberGenerator()
        return draw(c, history: history, now: now, avoid: avoid, reroll: reroll, household: household, rng: &g)
    }

    /// Last-resort pick when every rule is exhausted. It isn't in the catalog, so no caps apply.
    static let freeChoice = Activity(id: "free-choice", emoji: "🚶", name: "Your call, offline", category: "rest",
        how: "Anything that isn't a screen. Stand up, step outside, stretch, tidy, or just sit by a window.",
        maxPerDay: 99, from: 0, to: 24, weight: 1)

    // MARK: rules

    static func eligible(_ a: Activity, _ c: Catalog, _ today: [Done], _ week: [Done], _ byId: [String: Activity],
                         now: Date, hour: Double, sunsetH: Double, month: Int, level: Int, reroll: Bool, sunriseH: Double = 0,
                         latest: [String: Done] = [:], weekday: Int? = nil, cal: Calendar = .current) -> Bool {
        if a.off == true { return false }
        let mine = today.filter { $0.id == a.id }
        // Always enforced: daily max, safety rules (vigorous/caffeine late), group caps, category caps.
        if mine.count >= a.maxPerDay { return false }
        let groups = a.groups ?? []
        if groups.contains("vig") && hour >= 18 { return false }
        if groups.contains("caff") && hour >= 14 { return false }
        if groups.contains("screen") && (hour >= 20 || reroll) && level < 3 { return false }
        for g in groups {
            guard let rule = c.groups[g] else { continue }
            let inGroup = today.filter { (byId[$0.id]?.groups ?? []).contains(g) }
            if inGroup.count >= rule.cap { return false }
            if level < 1, let gap = rule.gap, let last = inGroup.last,
               now.timeIntervalSince(last.at) < Double(gap) * 60 { return false }
        }
        if let rule = c.categories[a.category], today.filter({ $0.category == a.category }).count >= rule.cap, level < 3 { return false }
        if let wk = weeklyLimit(a, latest: latest) {
            let since = weekWindowStart(a, now: now, cal: cal).timeIntervalSinceReferenceDate
            if week.filter({ $0.id == a.id && $0.at.timeIntervalSinceReferenceDate > since }).count >= wk { return false }
        }
        if (a.notFirst == true || groups.contains("screen")) && today.isEmpty && level < 3 { return false }
        if let ms = a.months, !ms.contains(month), level < 3 { return false }
        if let ds = a.days, !ds.contains(weekday ?? Calendar.current.component(.weekday, from: now)), level < 3 { return false }
        let dayOver = today.contains(where: { byId[$0.id]?.endsDay == true })
        if (a.afterDay == true) != dayOver { return false }

        if level < 2 {
            if hour < a.from || hour >= a.to { return false }
            if a.daylight == true && hour > sunsetH - 25.0 / 60 { return false }
            // Sun-timed items follow the real sun on your house, not the clock.
            if a.anchor == "sun" && (hour < sunriseH - 0.25 || hour >= sunriseH + 3) { return false }
            if a.soft == "sunset" && (hour < sunsetH - 1.25 || hour > sunsetH + 0.25) { return false }
        } else {
            if a.daylight == true && hour > sunsetH { return false }   // however short the list: no walks in the dark
        }
        if level < 1 {
            if let gap = a.minGap, let last = mine.last, now.timeIntervalSince(last.at) < Double(gap) * 60 { return false }
            // Never two play breaks in a row.
            if a.category == "play", today.last?.category == "play" { return false }
            // Posture: after 2 seated breaks in a row, you must stand or move.
            if a.seated == true {
                let last2 = today.suffix(2).compactMap { byId[$0.id] }
                if last2.count == 2 && last2.allSatisfy({ $0.seated == true }) { return false }
            }
        }
        return true
    }

    // MARK: rooms & nature

    /// A clean-* room item (group "clean").
    static func isRoom(_ a: Activity) -> Bool { (a.groups ?? []).contains("clean") }

    /// The most recent completed entry per item id, across all of `history`.
    static func latestCompleted(_ history: [Done]) -> [String: Done] {
        var out: [String: Done] = [:]
        for d in history where d.completed == true {
            if let p = out[d.id], p.at.timeIntervalSinceReferenceDate >= d.at.timeIntervalSinceReferenceDate { continue }
            out[d.id] = d
        }
        return out
    }

    /// Weekly cap after the mess rating: a room last found rough (3) may come up 3×/week, meh (2) 2×/week.
    static func weeklyLimit(_ a: Activity, latest: [String: Done]) -> Int? {
        guard let wk = a.weeklyMax else { return nil }
        guard isRoom(a), let mess = latest[a.id]?.mess else { return wk }
        return mess >= 3 ? max(wk, 3) : mess == 2 ? max(wk, 2) : wk
    }

    /// Where an item's weekly count starts: 7 days back, or for weekday-limited items the start of the
    /// current run of allowed days (so a Saturday lesson doesn't block next Thursday).
    static func weekWindowStart(_ a: Activity, now: Date, cal: Calendar = .current) -> Date {
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        guard let ds = a.days, !ds.isEmpty, ds.count < 7 else { return weekAgo }
        let wd = cal.component(.weekday, from: now)
        var back = 0
        while back < 6, ds.contains((wd - back - 2 + 14) % 7 + 1) { back += 1 }
        let runStart = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now)) ?? weekAgo
        return max(weekAgo, runStart.addingTimeInterval(-1))
    }

    /// Completed outdoor minutes in the last 7 days (the nature goal is 120/week). Unknown length counts as 25.
    static func outdoorMinutes(history: [Done], now: Date, cal: Calendar = .current) -> Double {
        let weekAgo = now.addingTimeInterval(-7 * 86400).timeIntervalSinceReferenceDate
        return history.filter { d in
            d.completed == true && d.category == "outdoors"
                && d.at.timeIntervalSinceReferenceDate > weekAgo && d.at.timeIntervalSinceReferenceDate <= now.timeIntervalSinceReferenceDate
        }.reduce(0) { $0 + ($1.mins ?? 25) }
    }

    // MARK: helpers

    static func hourOf(_ d: Date, _ cal: Calendar) -> Double {
        let c = cal.dateComponents([.hour, .minute, .second], from: d)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    static func parseSpan(_ s: String) -> (Double, Double)? {
        let parts = s.split(separator: "-").map { p -> Double? in
            let hm = p.split(separator: ":").compactMap { Double($0) }
            guard let h = hm.first else { return nil }
            return h + (hm.count > 1 ? hm[1] / 60 : 0)
        }
        guard parts.count == 2, let a = parts[0], let b = parts[1] else { return nil }
        return (a, b)
    }

    /// Sun altitude and azimuth (degrees) at `date`, NOAA fractional-year approximation.
    static func solar(_ date: Date, lat: Double, lon: Double) -> (alt: Double, az: Double) {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let n = Double(utc.ordinality(of: .day, in: .year, for: date) ?? 1)
        let hr = hourOf(date, utc)
        let g = 2 * Double.pi / 365 * (n - 1 + (hr - 12) / 24)
        let eq = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
            + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        let ha = (hr * 60 + eq + 4 * lon) / 4 - 180
        let haR = ha * .pi / 180, la = lat * .pi / 180
        let z = acos(max(-1, min(1, sin(la) * sin(decl) + cos(la) * cos(decl) * cos(haR))))
        let az = atan2(sin(haR), cos(haR) * sin(la) - tan(decl) * cos(la)) * 180 / .pi + 180
        return (90 - z * 180 / .pi, az.truncatingRemainder(dividingBy: 360))
    }

    static func horizonAt(_ az: Double, _ h: [Double]) -> Double {
        let n = h.count, step = 360 / Double(n), x = az / step
        let i = Int(x.rounded(.down)), t = x - Double(i)
        return h[((i % n) + n) % n] * (1 - t) + h[((i + 1) % n + n) % n] * t
    }

    /// When direct sun is actually on the house (local hours), accounting for the mountains.
    static var sunCache: [String: (Double, Double)] = [:]
    static func sunOnHouse(on date: Date, _ c: Catalog, _ cal: Calendar) -> (rise: Double, set: Double) {
        let h = (c.horizon?.isEmpty == false) ? c.horizon! : [0]
        let day = cal.startOfDay(for: date)
        let key = "\(day.timeIntervalSinceReferenceDate)|\(c.latitude)"
        if let v = sunCache[key] { return v }
        var rise: Double?, set: Double?
        for m in stride(from: 4 * 60, to: 21 * 60, by: 5) {
            let t = day.addingTimeInterval(Double(m) * 60)
            let s = solar(t, lat: c.latitude, lon: c.longitude)
            if s.alt > horizonAt(s.az, h) + 0.5 { if rise == nil { rise = Double(m) / 60 }; set = Double(m) / 60 }
        }
        let v = (rise ?? 12, set ?? 12)
        sunCache[key] = v; return v
    }

    /// NOAA sunrise-equation approximation (±2 min), good enough for "go outside before dark".
    static func sunset(on date: Date, lat: Double, lon: Double, cal: Calendar) -> Date {
        let n = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let g = 2 * Double.pi / 365 * (n - 1)
        let eq = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
            + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        let latR = lat * .pi / 180
        let cosHA = cos(90.833 * .pi / 180) / (cos(latR) * cos(decl)) - tan(latR) * tan(decl)
        let ha = acos(max(-1, min(1, cosHA))) * 180 / .pi
        let minutesUTC = 720 - 4 * (lon - ha) - eq
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let ymd = cal.dateComponents([.year, .month, .day], from: date)
        let midnightUTC = utc.date(from: ymd) ?? date
        return midnightUTC.addingTimeInterval(minutesUTC * 60)
    }

}

// MARK: - Capacity: the most real work you can do every day, consistently, plus a weekly reset.
// (Bob Knight via Huberman: find your daily max, stick to it, and reset yourself every week.)

enum DayLock: Equatable { case capacity(Int), reset, evening }

extension Engine {
    /// Work blocks done on `day` (each logged break follows one work block).
    static func blocks(_ history: [Done], on day: Date, cal: Calendar = .current) -> Int {
        history.filter { $0.skipped != true && cal.isDate($0.at, inSameDayAs: day) }.count
    }

    /// nil means you may work. `workdays` uses Calendar weekdays (1 = Sunday … 7 = Saturday).
    static func lock(history: [Done], now: Date, cap: Int, workdays: Set<Int>, endHour: Double = 24, cal: Calendar = .current) -> DayLock? {
        if !workdays.contains(cal.component(.weekday, from: now)) { return .reset }
        if hourOf(now, cal) >= endHour { return .evening }
        let n = blocks(history, on: now, cal: cal)
        return n >= cap ? .capacity(n) : nil
    }

    /// Workdays this week (Mon–today) where you hit your full capacity. Consistency beats blitzing.
    static func fullDaysThisWeek(_ history: [Done], now: Date, cap: Int, workdays: Set<Int>, cal: Calendar = .current) -> (Int, Int) {
        var full = 0, total = 0
        let wd = cal.component(.weekday, from: now)
        let back = (wd + 5) % 7            // days since Monday
        for i in 0...back {
            guard let d = cal.date(byAdding: .day, value: -i, to: now) else { continue }
            guard workdays.contains(cal.component(.weekday, from: d)) else { continue }
            total += 1
            if blocks(history, on: d, cal: cal) >= cap { full += 1 }
        }
        return (full, total)
    }

    /// Tonight, decided for you: one block every 30 minutes from `start` until wind-down, laptop closed.
    static func planEvening(_ c: Catalog, history: [Done], from start: Date, cal: Calendar = .current) -> [(at: Date, act: Activity)] {
        var h = history, out: [(Date, Activity)] = []
        let half = 1800.0
        var t = Date(timeIntervalSinceReferenceDate: (start.timeIntervalSinceReferenceDate / half).rounded(.up) * half)
        let stop = cal.startOfDay(for: start).addingTimeInterval(23 * 3600)
        while t.timeIntervalSinceReferenceDate < stop.timeIntervalSinceReferenceDate {
            let a = draw(c, history: h, now: t).pick
            if a.afterDay == true { break }
            out.append((t, a))
            h.append(Done(id: a.id, category: a.category, at: t, completed: true))
            if a.endsDay == true { break }
            t = t.addingTimeInterval(half)
        }
        return out
    }

    static let resetIdeas = [
        "🥾 Hike somewhere with a view",
        "🎣 Go fishing, or just sit by water",
        "🧑‍🤝‍🧑 See people in person. Make the plan today.",
        "🌲 Long walk in nature with the dog, no podcast",
        "🍳 Cook a big slow meal with someone",
        "🚲 Ride somewhere you've never been",
    ]

    /// The morning gate, until you write your own: the starter list's.
    static var morningChecklist: [String] { starterCatalog().checklist ?? [] }
}
