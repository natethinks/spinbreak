// Headless check of the activity engine. Simulates many days of 5/25 cycles and asserts the hard rules.
// Run: swiftc -O Engine.swift Starter.swift tests/main.swift -o /tmp/enginesim && /tmp/enginesim [days]
import Foundation

struct SplitMix64: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15; var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/Denver")!
let c = Engine.starterCatalog()
let byId = Dictionary(uniqueKeysWithValues: (c.activities + [Engine.freeChoice]).map { ($0.id, $0) })
var freeCount = 0
var rng = SplitMix64(s: 42)
let days = Int(CommandLine.arguments.dropFirst().first ?? "1000") ?? 1000

var history: [Done] = []
var failures: [String] = []
var softBreaks = [String: Int]()       // window/daylight relaxations (allowed fallback, but tracked)
var catTotals = [String: Int](), itemTotals = [String: Int]()
var breaksTotal = 0, anchoredTotal = 0, rerolls = 0
var sampleDay: [String] = []

func fail(_ s: String) { if failures.count < 30 { failures.append(s) } }

let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
var lessonDraws = 0, messRecorded = 0

/// One simulated day of 5/25 cycles. Picks are appended to `history`; `check` runs the hard-rule asserts.
func simulateDay(_ dayIdx: Int, _ day: Date, _ history: inout [Done], _ rng: inout SplitMix64,
                 check: Bool, onPick: (Activity) -> Void = { _ in }) {
    // Day starts between 7:45 and 8:45, ends by 22:30. Each cycle: 5 min work + 25 min break + 0–8 min slop.
    var t = day.addingTimeInterval(Double.random(in: 7.75...8.75, using: &rng) * 3600)
    let end = day.addingTimeInterval(22.5 * 3600)
    var today: [Done] = []
    while true {
        t = t.addingTimeInterval(5 * 60)              // work block
        if t >= end { break }
        var d = Engine.draw(c, history: history, now: t, calendar: cal, rng: &rng)
        if Double.random(in: 0..<1, using: &rng) < 0.2 {   // user rerolls 20% of the time
            if check { rerolls += 1 }
            let r = Engine.draw(c, history: history, now: t, avoid: d.pick.id, reroll: true, calendar: cal, rng: &rng)
            if check, r.pick.groups?.contains("screen") == true { fail("reroll landed on screen item \(r.pick.id)") }
            d = r
        }
        let a = d.pick
        onPick(a)
        // Chores: the user sometimes rates how bad the room was (1 fine, 2 meh, 3 rough).
        var mess: Int? = nil
        if Engine.isRoom(a), Double.random(in: 0..<1, using: &rng) < 0.7 { mess = Int.random(in: 1...3, using: &rng) }

        if check {
            if a.id == Engine.freeChoice.id { freeCount += 1 }
            if d.anchored { anchoredTotal += 1 }
            let h = Engine.hourOf(t, cal)
            let sunsetH = Engine.hourOf(Engine.sunset(on: t, lat: c.latitude, lon: c.longitude, cal: cal), cal)
            let weekday = cal.component(.weekday, from: t)

            // ---- hard rules (must never break) ----
            let mineToday = today.filter { $0.id == a.id }.count
            if a.id != Engine.freeChoice.id && mineToday >= a.maxPerDay { fail("day \(dayIdx) \(a.id) over maxPerDay") }
            let gs = a.groups ?? []
            if gs.contains("vig") && h >= 18 { fail("vigorous at \(h)") }
            if gs.contains("caff") && h >= 14 { fail("caffeine at \(h)") }
            for g in gs {
                let n = today.filter { (byId[$0.id]?.groups ?? []).contains(g) }.count
                if let cap = c.groups[g]?.cap, n >= cap { fail("day \(dayIdx) group \(g) over cap with \(a.id)") }
            }
            if gs.contains("screen") && today.isEmpty { fail("screen item as first break") }
            // Weekly cap, raised for rooms last rated meh/rough.
            if let wk = Engine.weeklyLimit(a, latest: Engine.latestCompleted(history)) {
                let since = Engine.weekWindowStart(a, now: t, cal: cal)
                let n = history.filter { $0.id == a.id && $0.at > since }.count
                if n >= wk { fail("day \(dayIdx) \(a.id) over weekly cap \(wk)") }
            }
            if let ds = a.days, !ds.contains(weekday) { fail("day \(dayIdx) \(a.id) on weekday \(weekday), allowed \(ds)") }
            if a.id == "lesson" { lessonDraws += 1 }
            if a.category == "play", today.last?.category == "play" { softBreaks["play-back-to-back", default: 0] += 1 }
            // ---- soft rules (only relaxed in fallback; count how often) ----
            if h < a.from || h >= a.to { softBreaks["outside-window", default: 0] += 1 }
            if a.daylight == true && h > sunsetH { fail("daylight item \(a.id) after sunset at \(h)") }
            if mess != nil { messRecorded += 1 }
        }

        today.append(Done(id: a.id, category: a.category, at: t, completed: true, mess: mess))
        history.append(today.last!)
        if check {
            catTotals[a.category, default: 0] += 1; itemTotals[a.id, default: 0] += 1; breaksTotal += 1
            if dayIdx == 3 {
                let f = DateFormatter(); f.timeZone = cal.timeZone; f.dateFormat = "HH:mm"
                sampleDay.append("\(f.string(from: t))  \(d.anchored ? "📌" : "  ") \(a.title)")
            }
        }
        t = t.addingTimeInterval(25 * 60 + Double.random(in: 0...480, using: &rng))
    }
}

for dayIdx in 0..<days {
    let day = cal.date(byAdding: .day, value: dayIdx, to: start)!
    simulateDay(dayIdx, day, &history, &rng, check: true)
    // keep history bounded like the app does (45 days)
    let cutoff = day.addingTimeInterval(-45 * 86400)
    history.removeAll { $0.at < cutoff }
}

// ---- Room survey: from an empty history, every clean-* room should come up within the first week. ----
let rooms = Set(c.activities.filter(Engine.isRoom).map(\.id))
let trials = 200
var surveyed = 0, roomsSeenTotal = 0, missed = [String: Int]()
for trial in 0..<trials {
    var h: [Done] = [], r = SplitMix64(s: UInt64(1000 + trial)), seen = Set<String>()
    let s0 = cal.date(byAdding: .day, value: trial % 7, to: start)!     // vary the starting weekday
    for i in 0..<7 {
        simulateDay(i, cal.date(byAdding: .day, value: i, to: s0)!, &h, &r, check: false) { a in
            if rooms.contains(a.id) { seen.insert(a.id) }
        }
    }
    roomsSeenTotal += seen.count; for m in rooms.subtracting(seen) { missed[m, default: 0] += 1 }
    if seen == rooms { surveyed += 1 }
}
let surveyFrac = Double(surveyed) / Double(trials)

let f = DateFormatter(); f.timeZone = cal.timeZone; f.dateFormat = "h:mm a"
print("Sunset Denver Nov 3: \(f.string(from: Engine.sunset(on: cal.date(from: DateComponents(year: 2026, month: 11, day: 3))!, lat: c.latitude, lon: c.longitude, cal: cal)))")
print("Simulated \(days) days, \(breaksTotal) breaks (\(String(format: "%.1f", Double(breaksTotal) / Double(days)))/day), \(rerolls) rerolls, \(anchoredTotal) anchored")
print("\nAvg per day by category:")
for (k, v) in catTotals.sorted(by: { $0.value > $1.value }) {
    let rule = c.categories[k]
    print(String(format: "  %-15@ %4.1f   (target %d, cap %d)", k as NSString, Double(v) / Double(days), rule?.target ?? 0, rule?.cap ?? 0))
}
print("\nAvg per day by activity:")
for a in c.activities {
    print(String(format: "  %4.2f  %@", Double(itemTotals[a.id] ?? 0) / Double(days), a.title as NSString))
}
print("\nSample day (day 4):"); sampleDay.forEach { print("  " + $0) }
print("\nFree-choice fallbacks: \(freeCount)")
print("\nNature: last-7-day outdoor minutes at end of sim: \(Int(Engine.outdoorMinutes(history: history, now: history.last?.at ?? start, cal: cal)))")
print("Lesson draws: \(lessonDraws), room mess ratings recorded: \(messRecorded)")
print(String(format: "Room survey: all %d rooms drawn within 7 days in %d/%d trials (%.1f%%), avg %.2f rooms seen",
             rooms.count, surveyed, trials, surveyFrac * 100, Double(roomsSeenTotal) / Double(trials)))
if !missed.isEmpty { print("  rooms missed in week 1: \(missed.sorted { $0.key < $1.key })") }
if surveyFrac < 0.9 { fail(String(format: "room survey only %.1f%% (< 90%%)", surveyFrac * 100)) }
print("\nSoft-rule relaxations (fallback only): \(softBreaks.isEmpty ? "none" : "\(softBreaks)")")
if failures.isEmpty { print("\n✅ HARD RULES: 0 violations") } else {
    print("\n❌ HARD RULE VIOLATIONS:"); failures.forEach { print("  " + $0) }; exit(1)
}
