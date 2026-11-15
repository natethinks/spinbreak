// SpinBreak for macOS: a menu bar timer for short work blocks and long breaks.
// When work ends, a full-screen break screen spins up your activity and stays up for the whole break.
// A Reminders alarm dings your iPhone and Watch when it's time to come back.
// Build: ./build.sh  (system swiftc + Apple frameworks only)
import AppKit
import EventKit
import Network
import ServiceManagement
import SwiftUI
import CryptoKit

// `open SpinBreak.app --args --fast` treats minutes as seconds for testing.
let unit: TimeInterval = CommandLine.arguments.contains("--fast") ? 1 : 60

/// `SpinBreak --sandbox <folder>`: run against a throwaway data folder and its own settings, without asking for
/// Calendar or Reminders and without touching login items. For trying a build next to a real install.
let sandbox: String? = { let a = CommandLine.arguments; return a.firstIndex(of: "--sandbox").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }()
/// Where settings live: the app's own defaults, or a separate set when sandboxed.
let prefs: UserDefaults = sandbox == nil ? .standard : (UserDefaults(suiteName: "com.nate.spinbreak.sandbox") ?? .standard)

extension Engine {
    /// What a fresh install (or "Restore the starter list") gets.
    static func freshCatalog() -> Catalog { starterCatalog() }
}

extension Activity {
    /// Housework: gets a mess rating afterwards and an "already done" button. Rooms count whatever category
    /// an AI-made list put them in.
    var isChore: Bool { category == "home" || Engine.isRoom(self) }
}

/// One stretch at the computer: from Go until the break starts. Paused time still counts while you're
/// actually using the Mac (that's the "I needed more than 5 minutes" time); idle time doesn't.
struct WorkSession: Codable {
    var start: Date
    var end: Date?
    var planned: Double                 // minutes the block was set for
    var pauses: Int = 0
    var eventID: String? = nil
    var mins: Double { (end ?? Date()).timeIntervalSince(start) / 60 }
    var over: Double { max(0, mins - planned) }
}

enum Stage: String { case workReady, working, workPaused, choosing, onBreak, breakDone, morning, dayOff, evening }

/// The morning screen laid over whatever is going on, without touching the stage or a running timer:
/// .review is today's brief and checklist again (after skipping it, or on a day off), .preview is a blank one.
enum MorningPeek { case review, preview }

/// How the last run of the brief writer went. Saved as brief-status.json so the AI that set it up can check its work.
struct BriefStatus: Codable {
    var state: String                   // running, ok, failed
    var kind: String                    // morning, evening
    var started: Date
    var finished: Date? = nil
    var detail = ""
    var brief = ""                      // the file it was asked to write
    var log = "brief.log"
}

final class Brain: ObservableObject {
    let d = prefs
    let dir: URL = {
        let fm = FileManager.default, support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let sandbox { let u = URL(fileURLWithPath: sandbox, isDirectory: true); try? fm.createDirectory(at: u, withIntermediateDirectories: true); return u }
        let u = support.appendingPathComponent("SpinBreak", isDirectory: true)
        // Versions before 1.3 kept a "friends edition" apart, in its own folder and settings. Bring those along once.
        let old = support.appendingPathComponent("SpinBreak-Friends", isDirectory: true)
        if !fm.fileExists(atPath: u.path), fm.fileExists(atPath: old.path) {
            try? fm.copyItem(at: old, to: u)
            for (k, v) in UserDefaults.standard.persistentDomain(forName: "com.nate.spinbreak.friends") ?? [:] where prefs.object(forKey: k) == nil { prefs.set(v, forKey: k) }
        }
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    var catalogURL: URL { dir.appendingPathComponent("activities.json") }
    var historyURL: URL { dir.appendingPathComponent("history.json") }
    var workURL: URL { dir.appendingPathComponent("work.json") }
    @Published var work: [WorkSession] = []
    var openWork: Int? { work.lastIndex { $0.end == nil } }
    var workToday: [WorkSession] { work.filter { Calendar.current.isDateInToday($0.start) } }
    func saveWork() {
        let cutoff = Date().addingTimeInterval(-60 * 86400).timeIntervalSinceReferenceDate
        work.removeAll { $0.start.timeIntervalSinceReferenceDate < cutoff }
        try? JSONEncoder.iso.encode(work).write(to: workURL, options: .atomic)
    }
    /// "1h 42m on the computer · 3 ran long (+24m)"
    var workSummary: String {
        let w = workToday; guard !w.isEmpty else { return "💻 No computer time logged yet today" }
        let total = Int(w.reduce(0) { $0 + $1.mins }.rounded()), long = w.filter { $0.over >= 1 }
        let extra = Int(long.reduce(0) { $0 + $1.over }.rounded())
        return "💻 \(Brain.hm(total)) on the computer today" + (long.isEmpty ? "" : " · \(long.count) ran long (+\(Brain.hm(extra)))")
    }
    static func hm(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }

    @Published var stage: Stage = .workReady
    @Published var endAt = Date()
    @Published var remaining: TimeInterval = 0
    @Published var act: Activity?
    @Published var rerolls = 1
    @Published var snoozed = false
    @Published var spinning = false
    @Published var reel: [Activity] = []
    @Published var reelPos = 0.0
    var reelAnim: (from: Double, to: Double, start: Date, dur: Double)?
    @Published var dingNote = ""
    @Published var anchored = false
    @Published var history: [Done] = []
    var warned = false
    var reminderID: String?
    var napGuard: NSObjectProtocol?

    var workMin: Int { get { d.object(forKey: "work") as? Int ?? 5 } set { d.set(newValue, forKey: "work") } }
    var breakMin: Int { get { d.object(forKey: "break") as? Int ?? 25 } set { d.set(newValue, forKey: "break") } }
    var workLen: TimeInterval { Double(workMin) * unit }
    var cap: Int { get { d.object(forKey: "cap") as? Int ?? 14 } set { d.set(newValue, forKey: "cap") } }
    var weekendsOff: Bool { get { d.object(forKey: "weekendsOff") as? Bool ?? true } set { d.set(newValue, forKey: "weekendsOff") } }
    var focusGuard: Bool { get { d.object(forKey: "focusGuard") as? Bool ?? false } set { d.set(newValue, forKey: "focusGuard") } }
    var workdays: Set<Int> { weekendsOff ? [2, 3, 4, 5, 6] : Set(1...7) }
    static func dayKey(_ t: Date = Date()) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: t) }
    var morningDone: Bool { get { d.string(forKey: "morningDay") == Brain.dayKey() } set { d.set(newValue ? Brain.dayKey() : nil, forKey: "morningDay") } }
    var overridden: Bool { get { d.string(forKey: "overrideDay") == Brain.dayKey() } set { d.set(newValue ? Brain.dayKey() : nil, forKey: "overrideDay") } }
    var lockOff = false                 // snapshots only: draw a workday's screens on a day off, without saving anything
    var lock: DayLock? { overridden || lockOff ? nil : Engine.lock(history: history, now: Date(), cap: cap, workdays: workdays, endHour: Double(workEnd)) }
    var workEnd: Int { get { d.object(forKey: "workEnd") as? Int ?? 17 } set { d.set(newValue, forKey: "workEnd") } }
    /// After the workday ends, the screen locks to tonight's plan (hold for 10 min of emergency access).
    var eveningLock: Bool { get { d.object(forKey: "eveningLock") as? Bool ?? true } set { d.set(newValue, forKey: "eveningLock") } }
    /// A new install opens on Settings; nothing goes full-screen until you've made the list yours.
    /// (An install with a break log from before this setting existed counts as set up.)
    var setupDone: Bool {
        get { d.object(forKey: "setupDone") as? Bool ?? FileManager.default.fileExists(atPath: historyURL.path) }
        set { d.set(newValue, forKey: "setupDone"); objectWillChange.send() }
    }
    var checklist: [String] { catalog().checklist ?? Engine.morningChecklist }
    @Published var tonight: [Planned] = []
    @Published var eveNow: (title: String, how: String, end: Date)?
    @Published var eveNext: (title: String, at: Date)?
    var eveUnlockedUntil: Date?
    var blocksToday: Int { Engine.blocks(history, on: Date()) }
    /// Today's ticked checklist items. Kept for the day, so leaving the morning screen and coming back loses nothing.
    @Published var checks: Set<Int> = [] { didSet { if peek != .preview { d.set(["day": Brain.dayKey(), "on": checks.sorted()], forKey: "morningChecks") } } }
    var savedChecks: Set<Int> {
        guard let m = d.dictionary(forKey: "morningChecks"), m["day"] as? String == Brain.dayKey() else { return [] }
        return Set(m["on"] as? [Int] ?? [])
    }
    var checksLeft: Int { checklist.indices.filter { !checks.contains($0) }.count }
    @Published var peek: MorningPeek?
    /// Off the morning screen for a few minutes ("I need the laptop"); it comes back by itself at this time.
    @Published var awayUntil: Date?
    @Published var note = ""
    @Published var mess: Int? = nil       // chores: 1 fine, 2 meh, 3 rough

    struct RoomStat: Identifiable { let id: String; let title: String; let times: Int; let avgMins: Double?; let lastMins: Double?
        let firstMins: Double?; let mess: Int?; let lastDone: Date?; let roughCount: Int
        /// Higher = needs attention: rough and getting slower, or never looked at.
        var attention: Double { times == 0 ? 50 : Double(mess ?? 2) * 10 + Double(roughCount) * 3 + (avgMins ?? 0) / 5 + max(0, (lastMins ?? 0) - (firstMins ?? 0)) / 2
            + min(14, (lastDone.map { Date().timeIntervalSince($0) / 86400 } ?? 14)) }
    }
    var houseStats: [RoomStat] {
        let home = catalog().activities.filter { Engine.isRoom($0) || ($0.category == "home" && ($0.id.hasPrefix("clean-") || ["kitchen", "laundry"].contains($0.id))) }
        return home.map { a in
            let done = (history + household).filter { $0.id == a.id && $0.completed == true }
                .sorted { $0.at.timeIntervalSinceReferenceDate < $1.at.timeIntervalSinceReferenceDate }
            let timed = done.compactMap(\.mins)
            return RoomStat(id: a.id, title: a.title, times: done.count,
                            avgMins: timed.isEmpty ? nil : timed.reduce(0, +) / Double(timed.count),
                            lastMins: timed.last, firstMins: timed.first,
                            mess: done.last(where: { $0.mess != nil })?.mess, lastDone: done.last?.at,
                            roughCount: done.filter { $0.mess == 3 }.count)
        }.sorted { $0.attention > $1.attention }
    }
    @Published var briefing: String?
    var briefingURL: URL { dir.appendingPathComponent("briefing-\(Brain.dayKey()).md") }
    func loadBriefing() { briefing = try? String(contentsOf: briefingURL, encoding: .utf8) }
    @Published var eveningBriefing: String?
    var eveningURL: URL { dir.appendingPathComponent("briefing-evening-\(Brain.dayKey()).md") }
    func loadEvening() { eveningBriefing = try? String(contentsOf: eveningURL, encoding: .utf8) }
    @Published var dayOffReason: DayLock = .reset
    @Published var briefRunning = false
    @Published var briefStatus: BriefStatus?
    var briefStatusURL: URL { dir.appendingPathComponent("brief-status.json") }
    /// The brief writer your AI set up: a script SpinBreak runs each morning.
    var briefJobURL: URL { dir.appendingPathComponent("brief.sh") }
    /// An evening brief is opt-in: it's written (for the evening lock screen) when this file says how.
    var eveningStyleURL: URL { dir.appendingPathComponent("brief-style-evening.md") }
    var hasEveningBrief: Bool { FileManager.default.fileExists(atPath: eveningStyleURL.path) && FileManager.default.fileExists(atPath: briefJobURL.path) }
    /// How this person wants their morning brief written (from their AI's setup, editable in Settings).
    var briefStyleURL: URL { dir.appendingPathComponent("brief-style.md") }
    var briefStyle: String? {
        get { try? String(contentsOf: briefStyleURL, encoding: .utf8) }
        set { if let v = newValue { try? v.write(to: briefStyleURL, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: briefStyleURL) } }
    }
    /// Rooms the rest of the house cleaned or is cleaning (shared "SpinBreak Home" calendar). Never part of `history`.
    @Published var household: [Done] = []
    @Published var briefMsg = ""
    @Published var houseLive: [(who: String, room: String)] = []
    var houseEventID: String? { get { d.string(forKey: "houseEventID") } set { d.set(newValue, forKey: "houseEventID") } }

    /// Apps allowed in front during the workday. Edit allowlist.json; a trailing * matches a prefix
    /// (e.g. com.google.Chrome.app.* = Chrome "Install as app" windows like Gmail).
    var allowURL: URL { dir.appendingPathComponent("allowlist.json") }
    func allowlist() -> [String] {
        if !FileManager.default.fileExists(atPath: allowURL.path) {
            let def = ["com.googlecode.iterm2", "com.apple.Terminal", "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap",
                       "com.apple.mail", "com.superhuman.electron", "com.google.Chrome", "com.google.Chrome.app.*", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.finder",
                       "com.apple.systempreferences", "com.apple.loginwindow", "com.apple.SecurityAgent", "com.1password.1password"]
            let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
            try? enc.encode(def).write(to: allowURL)
        }
        return (try? JSONDecoder().decode([String].self, from: Data(contentsOf: allowURL))) ?? []
    }
    var breakLen: TimeInterval { Double(breakMin) * unit }

    init() {
        if let data = try? Data(contentsOf: historyURL),
           let h = try? JSONDecoder.iso.decode([Done].self, from: data) { history = h }
        if let data = try? Data(contentsOf: workURL),
           let w = try? JSONDecoder.iso.decode([WorkSession].self, from: data) { work = w }
        remaining = workLen
        checks = savedChecks
        briefStatus = (try? Data(contentsOf: briefStatusURL)).flatMap { try? JSONDecoder.iso.decode(BriefStatus.self, from: $0) }
        // A run that was cut off by quitting the app didn't finish.
        if briefStatus?.state == "running" { briefStatus?.state = "failed"; briefStatus?.detail = "SpinBreak quit while the brief was being written." }
        // Restore an in-progress break across relaunches.
        if let s = d.string(forKey: "stage").flatMap(Stage.init), [.onBreak, .breakDone].contains(s),
           let data = d.data(forKey: "act"), let a = try? JSONDecoder().decode(Activity.self, from: data) {
            act = a; endAt = d.object(forKey: "endAt") as? Date ?? Date(); reminderID = d.string(forKey: "reminderID")
            stage = endAt > Date() ? .onBreak : .breakDone
        }
        // Restore a running work block too (relaunches shouldn't eat your timer).
        if d.string(forKey: "stage") == Stage.working.rawValue, let e = d.object(forKey: "endAt") as? Date {
            endAt = e; stage = .working
        }
        // …and a paused one.
        if d.string(forKey: "stage") == Stage.workPaused.rawValue {
            remaining = max(60, d.object(forKey: "remaining") as? Double ?? 60); stage = .workPaused
            endAt = d.object(forKey: "endAt") as? Date ?? Date()
        }
    }

    func persist() {
        d.set(stage.rawValue, forKey: "stage"); d.set(endAt, forKey: "endAt"); d.set(remaining, forKey: "remaining")
        d.set(act.flatMap { try? JSONEncoder().encode($0) }, forKey: "act"); d.set(reminderID, forKey: "reminderID")
    }
    func saveHistory() {
        let cutoff = Date().addingTimeInterval(-45 * 86400)
        history.removeAll { $0.at.timeIntervalSinceReferenceDate < cutoff.timeIntervalSinceReferenceDate }
        try? JSONEncoder.iso.encode(history).write(to: historyURL, options: .atomic)
    }

    /// The list is asked for constantly (every row of the spin, every second of the start window), so the decoded
    /// copy is kept until the file changes on disk.
    private var catalogCache: (stamp: Date, catalog: Catalog)?
    func catalog() -> Catalog {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: catalogURL.path))?[.modificationDate] as? Date
        if let stamp, let c = catalogCache, c.stamp == stamp { return c.catalog }
        if stamp == nil {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(Engine.freshCatalog()).write(to: catalogURL)
        }
        guard let data = try? Data(contentsOf: catalogURL), let c = try? JSONDecoder().decode(Catalog.self, from: data),
              !c.activities.isEmpty else {
            // Keep a copy of a file that no longer parses, so a hand edit gone wrong isn't lost when Settings saves.
            let bad = dir.appendingPathComponent("activities.broken.json")
            if !FileManager.default.fileExists(atPath: bad.path) { try? FileManager.default.copyItem(at: catalogURL, to: bad) }
            return Engine.freshCatalog()
        }
        if let stamp { catalogCache = (stamp, c) }
        return c
    }

    // Today's stats
    var today: [Done] { history.filter { Calendar.current.isDateInToday($0.at) } }
    var didCount: Int { today.filter { $0.completed == true }.count }
    var streak: Int { var n = 0; for x in today.reversed() { if x.completed == true { n += 1 } else if x.completed == false { break } }; return n }
    var breakMinutes: Int { didCount * breakMin }

    func shownReel(at now: Date) -> Double {
        guard let a = reelAnim else { return reelPos }
        let t = max(0, min(1, now.timeIntervalSince(a.start) / a.dur))
        return a.from + (a.to - a.from) * (1 - pow(1 - t, 3))
    }
    /// Rows per second right now: the derivative of the same ease-out `shownReel` uses.
    func reelSpeed(at now: Date) -> Double {
        guard let a = reelAnim else { return 0 }
        let t = max(0, min(1, now.timeIntervalSince(a.start) / a.dur))
        return (a.to - a.from) * 3 * pow(1 - t, 2) / a.dur
    }
    /// When the spin landed (the reveal animation runs off this), and whether that animation is still playing.
    @Published var landedAt: Date?
    @Published var celebrating = false

    /// Breaks started today in a category, counted the way the spinner counts them (anything not waved off as
    /// "already done"), next to the category's daily aim. The start window and the spin both read this.
    func progress(_ category: String) -> (done: Int, aim: Int) {
        (today.filter { $0.skipped != true && $0.category == category }.count, catalog().categories[category]?.target ?? 0)
    }
    /// One steady colour per category, in the order the categories sort.
    func tint(_ category: String) -> Color {
        let names = catalog().categories.keys.sorted()
        return sliceColors[(names.firstIndex(of: category) ?? 0) % sliceColors.count]
    }
    /// Rooms worth a look: rated rough last time, or cleaned once and then left for ten days. Rooms never
    /// cleaned yet don't count, or a new list would open on an alarm.
    var roomsNeedingYou: Int {
        houseStats.filter { r in r.times > 0 && (r.mess == 3 || (r.lastDone.map { Date().timeIntervalSince($0) > 10 * 86400 } ?? false)) }.count
    }

    func cancelDing(_ ding: Ding) { ding.cancel(reminderID); reminderID = nil; ding.endEvent(eventID); eventID = nil }
    var eventID: String? { get { d.string(forKey: "eventID") } set { d.set(newValue, forKey: "eventID") } }
}

// MARK: - Watch ding via Reminders (iCloud syncs it to iPhone + Apple Watch)

final class Ding {
    let ek = EKEventStore()

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        let finish: (Bool, Error?) -> Void = { ok, _ in DispatchQueue.main.async { done(ok) } }
        if #available(macOS 14.0, *) { ek.requestFullAccessToReminders(completion: finish) }
        else { ek.requestAccess(to: .reminder, completion: finish) }
    }

    func list() -> EKCalendar? {
        if let c = ek.calendars(for: .reminder).first(where: { $0.title == "SpinBreak" }) { return c }
        let src = ek.sources.first { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }
            ?? ek.defaultCalendarForNewReminders()?.source
        guard let src else { return ek.defaultCalendarForNewReminders() }
        let c = EKCalendar(for: .reminder, eventStore: ek); c.title = "SpinBreak"; c.source = src
        do { try ek.saveCalendar(c, commit: true); return c } catch { return ek.defaultCalendarForNewReminders() }
    }

    /// Calls back with (reminder id, user-facing note).
    func schedule(at date: Date, title: String, _ done: @escaping (String?, String) -> Void) {
        requestAccess { ok in
            guard ok else { return done(nil, "⚠️ Reminders access is off, so there's no watch ding. Enable it in System Settings › Privacy › Reminders.") }
            guard let cal = self.list() else { return done(nil, "⚠️ No Reminders list available, so there's no watch ding.") }
            let r = EKReminder(eventStore: self.ek)
            r.title = title; r.calendar = cal
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            r.addAlarm(EKAlarm(absoluteDate: date))
            do {
                try self.ek.save(r, commit: true)
                let t = DateFormatter(); t.timeStyle = .short
                done(r.calendarItemIdentifier, cal.source.sourceType == .local
                     ? "⚠️ Reminder saved to an On My Mac list, which won't reach your watch."
                     : "⌚ Your watch dings at \(t.string(from: date)).")
            } catch { done(nil, "⚠️ Couldn't save reminder: \(error.localizedDescription)") }
        }
    }

    func cancel(_ id: String?) {
        guard let id, let r = ek.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? ek.remove(r, commit: true)
    }

    // MARK: Calendar: fit breaks around meetings, and show the break on your watch's calendar.

    var calOK = false
    /// True once the Calendar permission question has an answer, yes or no. The brief doesn't wait on a yes.
    var calAsked = false
    func requestCalendar(_ done: @escaping () -> Void = {}) {
        let finish: (Bool, Error?) -> Void = { ok, _ in DispatchQueue.main.async { self.calOK = ok; self.calAsked = true; done() } }
        if #available(macOS 14.0, *) { ek.requestFullAccessToEvents(completion: finish) }
        else { ek.requestAccess(to: .event, completion: finish) }
    }

    /// Your next real meeting starting before `limit`: not all-day, not declined, not SpinBreak's own.
    func nextMeeting(before limit: Date) -> EKEvent? {
        guard calOK else { return nil }
        let now = Date()
        let cals = meetingCalendars()
        guard !cals.isEmpty else { return nil }
        let evs = ek.events(matching: ek.predicateForEvents(withStart: now.addingTimeInterval(-60), end: limit, calendars: cals))
        return evs.filter { e in
            !e.isAllDay && e.startDate.timeIntervalSince(now) > -60 && e.availability != .free
                && !(e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false)
                // An invite with a guest list you're not on is someone else's meeting.
                && (e.attendees?.isEmpty ?? true || e.attendees!.contains { $0.isCurrentUser } || e.organizer?.isCurrentUser == true)
        }.min { $0.startDate.timeIntervalSinceReferenceDate < $1.startDate.timeIntervalSinceReferenceDate }
    }

    /// A real meeting going on right now (same rules as nextMeeting), if any.
    func meetingNow() -> EKEvent? {
        guard calOK else { return nil }
        let cals = meetingCalendars(); guard !cals.isEmpty else { return nil }
        let now = Date()
        return ek.events(matching: ek.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(60), calendars: cals))
            .filter { e in
                !e.isAllDay && e.startDate <= now.addingTimeInterval(60) && e.endDate > now && e.availability != .free
                    && !(e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false)
                    && (e.attendees?.isEmpty ?? true || e.attendees!.contains { $0.isCurrentUser } || e.organizer?.isCurrentUser == true)
            }
            .max { $0.endDate.timeIntervalSinceReferenceDate < $1.endDate.timeIntervalSinceReferenceDate }
    }

    /// Which calendars hold *your* meetings. Picked in the menu; family calendars stay out.
    /// Until you pick, it skips birthdays, holidays, subscriptions and anything named like a family calendar.
    var allCalendars: [EKCalendar] { calOK ? ek.calendars(for: .event).filter { !$0.title.hasPrefix("SpinBreak") }.sorted { $0.title < $1.title } : [] }
    func defaultOn(_ c: EKCalendar) -> Bool {
        if [.birthday, .subscription].contains(c.type) { return false }
        let t = c.title.lowercased()
        // Add your own with: defaults write com.nate.spinbreak familyCalendarWords -array "a name" "another"
        let personal = ["family", "kids", "holiday", "birthday", "school", "home"] + (prefs.stringArray(forKey: "familyCalendarWords") ?? []).map { $0.lowercased() }
        return !personal.contains { t.contains($0) }
    }
    func isMeetingCalendar(_ c: EKCalendar) -> Bool {
        let picked = prefs.dictionary(forKey: "meetingCals") as? [String: Bool] ?? [:]
        return picked[c.calendarIdentifier] ?? defaultOn(c)
    }
    func setMeetingCalendar(_ id: String, _ on: Bool) {
        var picked = prefs.dictionary(forKey: "meetingCals") as? [String: Bool] ?? [:]
        picked[id] = on; prefs.set(picked, forKey: "meetingCals")
    }
    func meetingCalendars() -> [EKCalendar] { allCalendars.filter(isMeetingCalendar) }

    func eventsToday(dayOffset: Int = 0) -> [[String: String]] {
        guard calOK else { return [] }
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(dayOffset) * 86400), end = start.addingTimeInterval(86400)
        let cals = ek.calendars(for: .event).filter { !$0.title.hasPrefix("SpinBreak") }
        let t = DateFormatter(); t.timeStyle = .short
        return ek.events(matching: ek.predicateForEvents(withStart: start, end: end, calendars: cals))
            .sorted { $0.startDate.timeIntervalSinceReferenceDate < $1.startDate.timeIntervalSinceReferenceDate }
            .map { e in ["title": e.title ?? "", "calendar": e.calendar.title, "mine": isMeetingCalendar(e.calendar) ? "work/mine" : "family/other",
                         "when": e.isAllDay ? "all day" : "\(t.string(from: e.startDate))–\(t.string(from: e.endDate))"] }
    }

    func eventCalendar() -> EKCalendar? {
        if let c = ek.calendars(for: .event).first(where: { $0.title == "SpinBreak" }) { return c }
        let src = ek.sources.first { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }
            ?? ek.defaultCalendarForNewEvents?.source
        guard let src else { return nil }
        let c = EKCalendar(for: .event, eventStore: ek); c.title = "SpinBreak"; c.source = src
        c.cgColor = NSColor(red: 0.31, green: 0.82, blue: 0.65, alpha: 1).cgColor
        do { try ek.saveCalendar(c, commit: true); return c } catch { return nil }
    }

    /// Work blocks go on their own "SpinBreak Work" calendar: never a meeting, never mistaken for a break by the watch.
    func workCalendar() -> EKCalendar? {
        if let c = ek.calendars(for: .event).first(where: { $0.title == "SpinBreak Work" }) { return c }
        guard let src = eventCalendar()?.source else { return nil }
        let c = EKCalendar(for: .event, eventStore: ek); c.title = "SpinBreak Work"; c.source = src
        c.cgColor = NSColor(red: 0.45, green: 0.52, blue: 0.85, alpha: 1).cgColor
        do { try ek.saveCalendar(c, commit: true); return c } catch { return nil }
    }
    func workEvent(_ title: String, from: Date, to: Date) -> String? {
        guard calOK, let cal = workCalendar() else { return nil }
        let e = EKEvent(eventStore: ek); e.calendar = cal; e.title = title
        e.startDate = from; e.endDate = to; e.availability = .free
        do { try ek.save(e, span: .thisEvent, commit: true); return e.eventIdentifier } catch { return nil }
    }
    func updateEvent(_ id: String?, title: String? = nil, notes: String? = nil, end: Date) {
        guard let id, let e = ek.event(withIdentifier: id) else { return }
        if let title { e.title = title }; if let notes { e.notes = notes }
        e.endDate = max(e.startDate.addingTimeInterval(60), end); try? ek.save(e, span: .thisEvent, commit: true)
    }

    /// Puts the break on an iCloud "SpinBreak" calendar so the watch face's calendar shows it and when it ends.
    func breakEvent(_ title: String, notes: String, from: Date, to: Date) -> String? {
        guard calOK, let cal = eventCalendar() else { return nil }
        let e = EKEvent(eventStore: ek); e.calendar = cal; e.title = title; e.notes = notes
        e.startDate = from; e.endDate = to; e.availability = .busy
        do { try ek.save(e, span: .thisEvent, commit: true); return e.eventIdentifier } catch { return nil }
    }

    /// Tonight's plan as calendar events with an alert at each start, so your watch taps you through the evening.
    func scheduleTonight(_ plan: [Planned]) {
        guard calOK, let cal = eventCalendar() else { return }
        let d = prefs
        for id in d.stringArray(forKey: "tonightIDs") ?? [] { if let e = ek.event(withIdentifier: id) { try? ek.remove(e, span: .thisEvent, commit: false) } }
        var ids: [String] = []
        for p in plan {
            let e = EKEvent(eventStore: ek); e.calendar = cal; e.title = "\(p.act.emoji) \(p.act.name)"; e.notes = p.act.how
            e.startDate = p.at; e.endDate = p.at.addingTimeInterval(25 * 60); e.addAlarm(EKAlarm(relativeOffset: 0))
            try? ek.save(e, span: .thisEvent, commit: false)
            if let id = e.eventIdentifier { ids.append(id) }
        }
        try? ek.commit(); d.set(ids, forKey: "tonightIDs")
    }

    /// The SpinBreak block happening right now, and the one after it (from tonight's plan on the calendar).
    func blocks() -> (now: EKEvent?, next: EKEvent?) {
        guard calOK, let cal = ek.calendars(for: .event).first(where: { $0.title == "SpinBreak" }) else { return (nil, nil) }
        let now = Date()
        let evs = ek.events(matching: ek.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(6 * 3600), calendars: [cal]))
            .sorted { $0.startDate.timeIntervalSinceReferenceDate < $1.startDate.timeIntervalSinceReferenceDate }
        let cur = evs.last { $0.startDate.timeIntervalSince(now) <= 0 && $0.endDate.timeIntervalSince(now) > 0 }
        let nxt = evs.first { $0.startDate.timeIntervalSince(now) > 0 }
        return (cur, nxt)
    }

    func moveEventEnd(_ id: String, to end: Date) {
        guard let e = ek.event(withIdentifier: id) else { return }
        e.endDate = end; try? ek.save(e, span: .thisEvent, commit: true)
    }

    /// Ends the break event now (keeps it as an honest record of the time you were away).
    func endEvent(_ id: String?) {
        guard let id, let e = ek.event(withIdentifier: id) else { return }
        if e.endDate.timeIntervalSinceNow > 0 { e.endDate = max(e.startDate.addingTimeInterval(60), Date()); try? ek.save(e, span: .thisEvent, commit: true) }
    }
}

// MARK: - Full-screen overlay

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Overlay {
    var windows: [NSWindow] = []
    unowned let app: AppDelegate
    init(app: AppDelegate) { self.app = app }

    func show() {
        guard windows.isEmpty else { NSApp.activate(ignoringOtherApps: true); windows.first?.makeKeyAndOrderFront(nil); return }
        // The biggest display is the one you look at (your external monitor), whichever holds the menu bar.
        let main = NSScreen.screens.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? NSScreen.screens[0]
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.contentView = screen == main
                ? NSHostingView(rootView: OverlayView(b: app.brain, app: app))
                : NSHostingView(rootView: SideScreen(b: app.brain))
            w.setFrame(screen.frame, display: true)
            if screen == main { windows.insert(w, at: 0) } else { windows.append(w) }
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func hide() { windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll() }

    /// After sleep, lock, or plugging in a monitor, macOS shuffles windows between displays.
    /// Throw them away and rebuild one per screen so nothing is left covering a display without content.
    func rebuild() {
        guard !windows.isEmpty else { return }
        hide(); show()
    }
}

let bgWork = Color(red: 0.08, green: 0.07, blue: 0.10)
let accent = Color(red: 0.31, green: 0.82, blue: 0.65)
let warm = Color(red: 1, green: 0.48, blue: 0.35)
let sliceColors: [Color] = [warm, .yellow, accent, .blue, .purple, .pink, .green, .orange, .cyan, .indigo]
var spinFrames = 0      // frames drawn while the reel was moving (read by --spin-demo)
var demoFrames: [String: CGRect] = [:]      // where the spin's buttons are on screen (so --spin-demo can press them)
extension View {
    func noteFrame(_ name: String) -> some View {
        background(GeometryReader { g in let _ = { demoFrames[name] = g.frame(in: .global) }(); Color.clear })
    }
}

struct SideScreen: View {
    @ObservedObject var b: Brain
    var body: some View {
        ZStack {
            bgWork.ignoresSafeArea()
            VStack(spacing: 12) {
                Text(b.act?.emoji ?? "🎡").font(.system(size: 120))
                Text("Away from the screen.").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }
}

struct Planned: Identifiable { let at: Date; let act: Activity; var id: Double { at.timeIntervalSinceReferenceDate } }

/// Renders the morning briefing (a small markdown subset: #, ##, - bullets, **bold**, *italic*).
struct BriefingView: View {
    let text: String?; let writing: Bool
    var empty = "No briefing yet today. It's written each morning after 5."
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let text {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in line(raw) }
                } else {
                    Text("☕ Today's briefing").font(.system(size: 30, weight: .black, design: .serif))
                    Text(writing ? "Your AI is writing it now. Start on your list." : empty)
                        .font(.system(size: 18, design: .serif)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(28)
        }
        .frame(maxHeight: 820)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }
    @ViewBuilder func line(_ raw: String) -> some View {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("## ") {
            Text(String(s.dropFirst(3)).replacingOccurrences(of: "*", with: "").uppercased()).font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(1.5)
                .foregroundStyle(accent).padding(.top, 10)
        } else if s.hasPrefix("# ") {
            Text(md(String(s.dropFirst(2)))).font(.system(size: 32, weight: .bold, design: .serif)).fixedSize(horizontal: false, vertical: true)
        } else if s.hasPrefix("- ") || s.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").foregroundStyle(accent)
                Text(md(String(s.dropFirst(2)))).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 18, design: .serif)).foregroundStyle(.white.opacity(0.88))
        } else if !s.isEmpty {
            Text(md(s)).font(.system(size: 18, design: .serif)).foregroundStyle(.white.opacity(0.88)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - The spin
//
// A loot box, not a list: a closed box that rattles, a reel the height of the whole screen that slows until you
// can read each name going by, then a flash, everything else flying off the top and bottom, and the pick alone
// in a burst of its own colour. Everything is a function of the clock (`now`), so nothing can drift from the
// tick sounds, and any moment can be drawn on its own.

func easeOutBack(_ x: Double) -> Double { let c = 1.70158; return 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2) }
func noise(_ i: Int, _ salt: Double) -> Double { let x = sin(Double(i) * 12.9898 + salt) * 43758.5453; return x - x.rounded(.down) }

struct SpinView: View {
    @ObservedObject var b: Brain
    let app: AppDelegate
    let now: Date
    let pickMyself: () -> Void
    static let gold = Color(red: 1, green: 0.8, blue: 0.3), violet = Color(red: 0.74, green: 0.56, blue: 1)

    /// How special the pick is, which sets the colour of the whole reveal.
    enum Tier { case anchor, rare, usual }
    func tier(_ a: Activity) -> Tier {
        if b.anchored { return .anchor }
        if a.id != Engine.freeChoice.id, !Engine.isRoom(a), a.weight <= 1.5 { return .rare }
        return .usual
    }
    func colour(_ a: Activity) -> Color {
        switch tier(a) { case .anchor: return Self.gold; case .rare: return Self.violet; case .usual: return b.tint(a.category) }
    }
    /// "OUTDOORS · this makes 2 of 3 today": where the pick leaves that part of the day. A status, not a reason.
    func standing(_ a: Activity) -> String {
        let p = b.progress(a.category), name = pretty(a.category).uppercased()
        guard p.aim > 0 else { return name }
        return p.done + 1 <= p.aim ? "\(name) · this makes \(p.done + 1) of \(p.aim) today" : "\(name) · \(p.done + 1) today"
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size, k = min(1, size.height / 1000)          // shrink a little on small laptop screens
            let landed = !b.spinning && b.act != nil
            // Seconds since the reveal. Once it has finished playing, the screen is in its final state (buttons
            // live) whatever the clock says.
            let r = landed ? (b.celebrating ? max(0, now.timeIntervalSince(b.landedAt ?? .distantPast)) : 99) : 0
            let speed = b.spinning ? b.reelSpeed(at: now) : 0
            let glow = b.act.map(colour) ?? .white
            let _ = { if b.spinning { spinFrames += 1 } }()
            ZStack {
                rays(size, colour: glow, strength: landed ? 0.10 + 0.26 * max(0, 1 - r / 1.2) : (b.spinning ? 0.03 + 0.09 * (1 - min(1, speed / 30)) : 0.05))
                if b.spinning || (landed && r < 0.5) { reel(size, k: k, landed: landed, r: r, speed: speed) }
                if b.spinning { selector(size, k: k, slow: 1 - min(1, speed / 12)) }
                if !b.spinning && b.act == nil { box(k) }
                if landed, r < 1.6 { burst(size, colour: glow, r: r) }
                if landed, r < 0.3 { glow.opacity(0.5 * (1 - r / 0.3)).ignoresSafeArea() }
                if landed, let a = b.act { reveal(a, k: k, r: r) }
                VStack {
                    Text("Hands off the keyboard. The agents have it.")
                        .font(.system(size: 30 * k, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(landed ? 0.55 : 0.9))
                        .padding(.top, 54 * k)
                    Spacer()
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// Before the reel starts: the closed box, rattling.
    func box(_ k: Double) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        return Text("🎁").font(.system(size: 190 * k))
            .rotationEffect(.degrees(sin(t * 38) * 7)).scaleEffect(1 + 0.06 * sin(t * 19))
    }

    /// Light rays turning slowly behind everything. They brighten as the reel slows, and flare on the reveal.
    func rays(_ size: CGSize, colour: Color, strength: Double) -> some View {
        let turn = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) * 0.12
        return Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2), far = hypot(sz.width, sz.height), n = 16
            for i in 0..<n {
                let mid = Double(i) / Double(n) * 2 * .pi + turn, w = Double.pi / Double(n) * 0.5
                var p = Path(); p.move(to: c)
                p.addLine(to: CGPoint(x: c.x + cos(mid - w) * far, y: c.y + sin(mid - w) * far))
                p.addLine(to: CGPoint(x: c.x + cos(mid + w) * far, y: c.y + sin(mid + w) * far))
                p.closeSubpath()
                ctx.fill(p, with: .color(colour.opacity(strength)))
            }
        }
        .mask(RadialGradient(colors: [.white, .white.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: max(size.width, size.height) * 0.6))
        .frame(width: size.width, height: size.height)
    }

    /// The reel: one tile per activity, streaming from above the top edge to below the bottom one.
    func reel(_ size: CGSize, k: Double, landed: Bool, r: Double, speed: Double) -> some View {
        let rowH = 108 * k, n = max(1, b.reel.count)
        let pos = b.spinning ? b.shownReel(at: now) : b.reelPos, base = Int(pos.rounded(.down))
        let half = Int(size.height / rowH / 2) + 2
        let fly = landed ? pow(min(1, r / 0.5), 2) : 0                    // on the reveal, the rest leave the screen
        let streak = min(1, speed / 26)
        return ZStack {
            if !b.reel.isEmpty {
                ForEach((base - half)...(base + half), id: \.self) { i in
                    let d = Double(i) - pos, a = b.reel[((i % n) + n) % n], near = max(0, 1 - abs(d))
                    if !(landed && abs(d) < 0.5) {
                        tile(a, k: k, near: near)
                            .scaleEffect(x: 1, y: 1 + streak * 0.5)
                            .blur(radius: streak * 5)
                            .opacity(max(0.12, 1 - abs(d) * 0.13) * (1 - fly))
                            .offset(y: d * rowH * (1 + fly * 9))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        // The rows come out of the dark at the top and go back into it at the bottom.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.04), .init(color: .white, location: 0.24),
                                     .init(color: .white, location: 0.76), .init(color: .clear, location: 0.96)], startPoint: .top, endPoint: .bottom))
    }

    /// One row of the reel. `near` is 1 dead centre and 0 a full row away, so the row passing the middle swells.
    func tile(_ a: Activity, k: Double, near: Double) -> some View {
        let c = b.tint(a.category)
        return HStack(spacing: 20 * k) {
            Text(a.emoji).font(.system(size: (46 + 14 * near) * k))
            Text(a.name).font(.system(size: (38 + 16 * near) * k, weight: near > 0.5 ? .black : .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            Circle().fill(c).frame(width: 14 * k, height: 14 * k)
        }
        .padding(.horizontal, 30 * k)
        .frame(width: (780 + 80 * near) * k, height: 92 * k)
        .background(c.opacity(0.10 + 0.14 * near), in: RoundedRectangle(cornerRadius: 24 * k))
        .overlay(RoundedRectangle(cornerRadius: 24 * k).stroke(c.opacity(0.25 + 0.5 * near), lineWidth: 2))
    }

    /// The window the reel runs through: two bright rails and a pointer either side. It tightens as the reel slows.
    func selector(_ size: CGSize, k: Double, slow: Double) -> some View {
        let w = 900 * k, h = 108 * k
        return ZStack {
            RoundedRectangle(cornerRadius: 28 * k).stroke(Color.white.opacity(0.35 + 0.5 * slow), lineWidth: 3 + 2 * slow)
                .frame(width: w, height: h).shadow(color: .white.opacity(0.5 * slow), radius: 18)
            HStack {
                Text("▶").foregroundStyle(warm); Spacer(); Text("◀").foregroundStyle(warm)
            }
            .font(.system(size: 34 * k)).frame(width: w + 110 * k - 20 * k * slow)
        }
    }

    /// Bits of colour thrown out from the pick as it's revealed.
    func burst(_ size: CGSize, colour: Color, r: Double) -> some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2 - 80), out = 1 - pow(1 - min(1, r / 1.1), 3)
            let palette: [Color] = [colour, .white, colour, warm, accent, .yellow]
            for i in 0..<56 {
                let ang = noise(i, 1.3) * 2 * .pi, reach = (0.22 + 0.5 * noise(i, 7.7)) * sz.height
                let x = c.x + cos(ang) * reach * out * 1.5, y = c.y + sin(ang) * reach * out + 260 * r * r
                let side = 6 + 9 * noise(i, 3.1)
                var bit = ctx
                bit.translateBy(x: x, y: y); bit.rotate(by: .radians(r * (4 + 8 * noise(i, 5.5)) + ang))
                let shape = i % 3 == 0 ? Path(ellipseIn: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
                                       : Path(roundedRect: CGRect(x: -side / 2, y: -side / 4, width: side, height: side / 2), cornerRadius: 2)
                bit.fill(shape, with: .color(palette[i % palette.count].opacity(max(0, 1 - r / 1.5))))
            }
        }
        .frame(width: size.width, height: size.height).allowsHitTesting(false)
    }

    /// The pick, alone: its emoji in a lit frame, what it is, what to do, and (a beat later) the buttons.
    func reveal(_ a: Activity, k: Double, r: Double) -> some View {
        let c = colour(a), pop = 0.5 + 0.5 * easeOutBack(min(1, r / 0.45)), ready = min(1, max(0, (r - 0.55) / 0.35))
        return VStack(spacing: 18 * k) {
            Text(a.emoji).font(.system(size: 132 * k))
                .frame(width: 216 * k, height: 216 * k)
                .background(c.opacity(0.18), in: RoundedRectangle(cornerRadius: 52 * k))
                .overlay(RoundedRectangle(cornerRadius: 52 * k).stroke(c, lineWidth: 4))
                .shadow(color: c.opacity(0.8), radius: 46 * k)
                .scaleEffect(pop)
            switch tier(a) {
            case .anchor: Text("📌 DAILY ANCHOR · RIGHT ON TIME").font(.system(size: 15 * k, weight: .heavy, design: .rounded)).tracking(2).foregroundStyle(c)
            case .rare: Text("✨ RARE ONE · IT DOESN'T COME UP OFTEN").font(.system(size: 15 * k, weight: .heavy, design: .rounded)).tracking(2).foregroundStyle(c)
            case .usual: EmptyView()
            }
            Text(a.name).font(.system(size: 66 * k, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.6).frame(maxWidth: 1100 * k).scaleEffect(0.8 + 0.2 * min(1, pop))
            Text(a.how).font(.system(size: 26 * k, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center).frame(maxWidth: 860 * k).fixedSize(horizontal: false, vertical: true)
            Text(standing(a)).font(.system(size: 16 * k, weight: .heavy, design: .rounded)).tracking(1.5)
                .padding(.horizontal, 16 * k).padding(.vertical, 8 * k)
                .foregroundStyle(b.tint(a.category)).background(b.tint(a.category).opacity(0.14), in: Capsule())
            VStack(spacing: 14 * k) {
                HStack(spacing: 16) {
                    BigButton(title: "Go. I'm leaving.") { app.goBreak() }
                    if b.rerolls > 0 { BigButton(title: "Reroll (\(b.rerolls))", prominent: false) { app.spin(reroll: true) }.noteFrame("reroll") }
                    if a.isChore || a.id == "outdoor-chore" { BigButton(title: "✨ Already done", prominent: false) { app.alreadyDone() } }
                    if !b.snoozed { BigButton(title: "1 more minute", prominent: false) { app.snooze() }.noteFrame("snooze") }
                }
                Button("I'll pick it myself", action: pickMyself).buttonStyle(.plain)
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(accent)
            }
            .padding(.top, 10 * k).opacity(ready).allowsHitTesting(ready > 0.9)
        }
        .opacity(min(1, r / 0.12))
    }
}

struct BigButton: View {
    let title: String; var color: Color = accent; var prominent = true; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: prominent ? 26 : 18, weight: .bold, design: .rounded))
                .padding(.horizontal, prominent ? 36 : 22).padding(.vertical, prominent ? 18 : 12)
                .background(prominent ? color : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct HoldToUnlock: View {
    var label = "Emergency: hold 3s to unlock"
    let action: () -> Void
    @State private var pressing = false
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.08))
            Capsule().fill(warm.opacity(0.6)).frame(width: pressing ? 320 : 0)
                .animation(pressing ? .linear(duration: 3) : .easeOut(duration: 0.2), value: pressing)
            Text(pressing ? "Keep holding…" : label)
                .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
        }
        .frame(width: 320, height: 48)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: 3, pressing: { pressing = $0 }, perform: action)
    }
}

struct OverlayView: View {
    @ObservedObject var b: Brain
    let app: AppDelegate
    @State var picking = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [bgWork, Color(red: 0.05, green: 0.12, blue: 0.11)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if b.peek != nil { morning } else {
                switch b.stage {
                case .choosing: if picking { pickList } else { choosing }
                case .onBreak: onBreak
                case .breakDone: done
                case .morning: morning
                case .dayOff: dayOff
                case .evening: evening
                default: EmptyView()
                }
            }
        }
        .foregroundStyle(.white)
    }

    var choosing: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !b.spinning && !b.celebrating && b.act != nil)) { ctx in
            SpinView(b: b, app: app, now: ctx.date) { picking = true }
        }
        .ignoresSafeArea()
    }

    /// Every activity, tap one and go. For "the kitchen needs it, I'm cleaning now."
    var pickList: some View {
        VStack(spacing: 20) {
            Text("What are you doing?").font(.system(size: 44, weight: .black, design: .rounded))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(b.catalog().activities.filter { $0.afterDay != true }) { a in
                        Button { picking = false; b.act = a; b.anchored = false; app.goBreak() } label: {
                            Text("\(a.emoji)  \(a.name)").font(.system(size: 20, weight: .semibold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18).padding(.vertical, 14)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 1100)
            }
            .frame(maxHeight: 640)
            Button("Back to the spin") { picking = false }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
        }
    }

    var onBreak: some View {
        VStack(spacing: 22) {
            Text(b.act?.emoji ?? "☕").font(.system(size: 150))
            Text(b.act?.name ?? "Break").font(.system(size: 60, weight: .black, design: .rounded))
            Text(b.act?.how ?? "").font(.system(size: 22, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center).frame(maxWidth: 820)
            Text(timerInterval: Date()...max(Date(), b.endAt), countsDown: true)
                .font(.system(size: 110, weight: .bold, design: .rounded)).monospacedDigit()
            Text(b.dingNote).font(.system(size: 18, design: .rounded)).foregroundStyle(.white.opacity(0.65))
            if let a = b.act, Engine.isRoom(a), let l = b.houseLive.first {
                Text("🧹 \(l.who) is on the \(l.room.lowercased()) right now. You've got this one.")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(accent)
            }
            Spacer().frame(height: 30)
            HStack(spacing: 16) {
                BigButton(title: "✅ Done early", prominent: false) { app.finishEarly() }
                BigButton(title: "➕ 10 more min", prominent: false) { app.extendBreak() }
            }
            HoldToUnlock { app.unlock() }
        }
    }

    var morning: some View {
        HStack(alignment: .center, spacing: 70) {
            morningChecklist
            VStack(spacing: 14) {
                BriefingView(text: b.briefing, writing: b.briefRunning, empty: briefEmpty).frame(width: 640)
                HStack(spacing: 10) {
                    if app.briefScript != nil {
                        // A brief writer is set up: it runs by itself, and this is the nudge for when it hasn't.
                        if b.briefing == nil, !b.briefRunning { Button("✍️ Write it now") { app.rewriteBriefing() } }
                    } else {
                        Button(b.briefing == nil ? "📋 Copy today's request" : "📋 Copy request again") { app.copyBriefRequest() }
                        Button("📥 Paste brief") { app.pasteBrief() }
                        if b.peek == nil { Button("↗ Step away 3 min") { app.stepAway() } }
                    }
                }
                .buttonStyle(.bordered).controlSize(.large)
                if !b.briefMsg.isEmpty { Text(b.briefMsg).font(.system(size: 15, design: .rounded)).foregroundStyle(.white.opacity(0.65)) }
            }
        }
        .onAppear { b.loadBriefing() }
    }

    var briefEmpty: String {
        if app.briefScript == nil {
            return "Have your AI write it: copy today's request, paste it into ChatGPT, Claude or whichever you use, then copy its answer and paste it here."
        }
        if b.briefStatus?.state == "failed", b.briefStatus?.kind == "morning" {
            return "The brief writer didn't finish: \(b.briefStatus?.detail ?? ""). SpinBreak will try again; Settings › Your AI has the details."
        }
        return "No briefing yet today. It's written each morning after 5."
    }

    var morningChecklist: some View {
        VStack(spacing: 22) {
            Text("☀️").font(.system(size: 110))
            Text("Good morning. Before the agents:").font(.system(size: 46, weight: .black, design: .rounded))
            Text("Tap what's true. Be honest, nobody's watching but you.")
                .font(.system(size: 20, design: .rounded)).foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(b.checklist.enumerated()), id: \.offset) { i, item in
                    Button { if b.checks.contains(i) { b.checks.remove(i) } else { b.checks.insert(i) } } label: {
                        HStack(spacing: 14) {
                            Image(systemName: b.checks.contains(i) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 28)).foregroundStyle(b.checks.contains(i) ? accent : .white.opacity(0.4))
                            Text(item).font(.system(size: 26, weight: .semibold, design: .rounded))
                                .foregroundStyle(b.checks.contains(i) ? .white : .white.opacity(0.75))
                        }
                        .frame(width: 640, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            let left = b.checksLeft
            if let peek = b.peek {
                // Looking at it again (or previewing): nothing here starts or stops work.
                if peek == .preview {
                    Text("A preview. Nothing you tap here is kept.").font(.system(size: 18, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                } else if left > 0 {
                    Text("\(left) still open from this morning.").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(warm)
                }
                BigButton(title: peek == .preview ? "Close the preview" : "Back to it") { app.closePeek() }
            } else if left == 0 {
                BigButton(title: "Let me in. Start work.") { app.morningPassed() }
            } else {
                Text("\(left) to go. Go take care of it, I'll wait.").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(warm)
                BigButton(title: "💻 I need the laptop for 5 minutes", prominent: false) { app.lookAway() }
                HoldToUnlock(label: "Skip today: hold 3s") { app.morningPassed() }
                Text("Either way, this page stays in the 🍅 menu all day: This Morning's Brief.")
                    .font(.system(size: 14, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    var dayOff: some View {
        VStack(spacing: 22) {
            if b.dayOffReason != .reset {
                Text("🌙").font(.system(size: 90))
                Text(b.dayOffReason == .evening ? "Work's done. Here's tonight." : "That's your capacity. Here's the rest of today.")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                Text("Laptop closes now. The rest of the day is yours.")
                    .font(.system(size: 22, design: .rounded)).foregroundStyle(accent)
            } else {
                Text("🌲").font(.system(size: 130))
                Text("Reset day. No agents.").font(.system(size: 58, weight: .black, design: .rounded))
                Text("Figure out a non-destructive way to reset yourself every week.")
                    .font(.system(size: 22, design: .rounded).italic()).foregroundStyle(.white.opacity(0.7))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Engine.resetIdeas, id: \.self) { Text($0).font(.system(size: 24, weight: .semibold, design: .rounded)) }
                }
            }
            let (full, total) = Engine.fullDaysThisWeek(b.history, now: Date(), cap: b.cap, workdays: b.workdays)
            Text("This week: \(full)/\(total) full workdays").font(.system(size: 16, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            BigButton(title: "Close it up 👋") { app.closeDay() }
            HoldToUnlock(label: "Work anyway: hold 3s") { app.overrideDay() }
        }
    }

    @State private var eveTab = 0
    var evening: some View {
        HStack(alignment: .center, spacing: 60) {
            eveningNow.frame(maxWidth: 820)
            if b.hasEveningBrief { VStack(spacing: 12) {
                Picker("", selection: $eveTab) { Text("Tonight").tag(0); Text("This morning").tag(1) }
                    .pickerStyle(.segmented).frame(width: 300)
                BriefingView(text: eveTab == 0 ? b.eveningBriefing : b.briefing, writing: eveTab == 0 && app.eveningRunning)
                    .frame(width: 620)
            } } else if b.briefing != nil {
                // No evening brief set up: this morning's is still worth a second read.
                BriefingView(text: b.briefing, writing: false).frame(width: 620)
            }
        }
        .onAppear { b.loadBriefing(); b.loadEvening() }
    }

    var eveningNow: some View {
        VStack(spacing: 22) {
            if let n = b.eveNow {
                Text("RIGHT NOW YOU'RE SUPPOSED TO BE").font(.system(size: 16, weight: .heavy, design: .rounded)).tracking(2).foregroundStyle(accent)
                Text(n.title).font(.system(size: 76, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                Text(n.how).font(.system(size: 24, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).frame(maxWidth: 820)
                Text(timerInterval: Date()...max(Date(), n.end), countsDown: true)
                    .font(.system(size: 90, weight: .bold, design: .rounded)).monospacedDigit()
            } else {
                Text("🌙").font(.system(size: 120))
                Text("Work's done for today.").font(.system(size: 64, weight: .black, design: .rounded))
                Text("Close the laptop. The evening is yours, and theirs.").font(.system(size: 24, design: .rounded)).foregroundStyle(.white.opacity(0.8))
            }
            if let x = b.eveNext {
                Text("Then at \(x.at.formatted(date: .omitted, time: .shortened)): \(x.title)")
                    .font(.system(size: 20, design: .rounded)).foregroundStyle(.white.opacity(0.6))
            }
            Text("Close the lid. See you tomorrow.").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(accent)
            Spacer().frame(height: 20)
            HoldToUnlock(label: "Emergency: hold 3s for 10 min") { app.eveningUnlock() }
        }
    }

    var done: some View {
        VStack(spacing: 26) {
            Text("👋").font(.system(size: 130))
            Text("Break's over. Welcome back.").font(.system(size: 54, weight: .black, design: .rounded))
            if let a = b.act {
                Text("Did you actually do it? \(a.emoji) \(a.name)").font(.system(size: 26, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("How'd it go? What else did you get done?").font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                TextField("Loaded the dishwasher on the way, swapped laundry, car was already clean…", text: $b.note, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 20, design: .rounded)).lineLimit(3...6)
                    .padding(14).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            .frame(width: 720)
            if b.act?.isChore == true {
                VStack(spacing: 8) {
                    Text("How bad was it when you started?").font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 12) {
                        ForEach([(1, "✨ Fine"), (2, "😐 Meh"), (3, "🔥 Rough")], id: \.0) { v, label in
                            Button { b.mess = v } label: {
                                Text(label).font(.system(size: 20, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 22).padding(.vertical, 12)
                                    .background(Color.white.opacity(b.mess == v ? 0.3 : 0.08), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            let ready = b.note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && (b.act?.isChore != true || b.mess != nil)
            HStack(spacing: 16) {
                BigButton(title: "✅ Did it. Start work") { app.finishBreak(didIt: true) }
                BigButton(title: "😅 Didn't. Start work", prominent: false) { app.finishBreak(didIt: false) }
            }
            .disabled(!ready).opacity(ready ? 1 : 0.35)
            if !ready { Text(b.act?.isChore == true && b.mess == nil ? "Rate the mess and write a line. It's your log." : "Write a line first. It's your log.").font(.system(size: 14, design: .rounded)).foregroundStyle(warm) }
            Text("Only honest ✅s count toward your streak. \(b.didCount) done today · \(b.streak)🔥")
                .font(.system(size: 16, design: .rounded)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// The small window you get from the Dock icon: where you are, the one button that matters, and how today
/// is going across the parts of your life. The house has its own window (`HouseView`).
struct Dashboard: View {
    @ObservedObject var b: Brain
    let app: AppDelegate
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 14) {
                Text(headline).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(b.stage == .onBreak ? accent : warm)
                now
                Divider()
                today
                Divider()
                VStack(spacing: 5) {
                    ForEach(Array(b.houseLive.enumerated()), id: \.offset) { _, l in Text("🧹 \(l.who) is cleaning: \(l.room)") }
                    if let m = app.ding.nextMeeting(before: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)) {
                        Text("📅 Next: \(m.title ?? "Meeting") at \(m.startDate.formatted(date: .omitted, time: .shortened))")
                    }
                    HStack(spacing: 12) {
                        if b.stage != .morning { Button("☀️ Brief") { app.showMorningAgain() } }
                        if !b.houseStats.isEmpty {
                            Button(b.roomsNeedingYou > 0 ? "🏠 The house · \(b.roomsNeedingYou) need\(b.roomsNeedingYou == 1 ? "s" : "") you" : "🏠 The house") { app.showHouse() }
                        }
                        Button("⚙️ Settings") { app.showSettings() }
                    }
                    .buttonStyle(.link)
                }
                .font(.system(size: 12, design: .rounded))
            }
            .padding(24).frame(width: 360)
        }
    }

    /// The top half: what's happening right now and the one thing to press. Every stage gets its own.
    @ViewBuilder var now: some View {
        let left = b.endAt.timeIntervalSinceNow
        switch b.stage {
        case .workReady:
            if let l = b.lock {
                // A day (or evening) off: no timer to tempt you, and working anyway takes the long way round.
                big(l == .reset ? "🌲" : "🌙", l == .reset ? "No work blocks today." : "Work's done for today.")
                BigButton(title: "Work anyway…", prominent: false) { app.startWork() }
            } else {
                clock(app.fmt(b.workLen)); BigButton(title: "Go") { app.startWork() }
            }
        case .working: clock(app.fmt(left)); BigButton(title: "Pause", prominent: false) { app.pauseWork() }
        case .workPaused: clock(app.fmt(b.remaining)); BigButton(title: "Resume") { app.startWork() }
        case .morning:
            big("☀️", b.awayUntil != nil ? "Your list is waiting. Back to it soon." : "\(b.checksLeft) to go on your morning list.")
            BigButton(title: "Show the morning screen") { app.overlay.show() }
        case .choosing: big("🎁", "Your break is being picked."); BigButton(title: "Show the spin") { app.overlay.show() }
        case .onBreak:
            Text(b.act.map { "\($0.emoji) \($0.name)" } ?? "").font(.system(size: 22, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
            clock(app.fmt(left)); BigButton(title: "Show the break screen", prominent: false) { app.overlay.show() }
        case .breakDone: big("👋", "How did it go?"); BigButton(title: "Answer and start work") { app.overlay.show() }
        case .dayOff: big(b.dayOffReason == .reset ? "🌲" : "🌙", "The rest of today is yours."); BigButton(title: "Show today's screen", prominent: false) { app.overlay.show() }
        case .evening: big("🌙", "Close the laptop."); BigButton(title: "Show the evening screen", prominent: false) { app.overlay.show() }
        }
    }
    func clock(_ t: String) -> some View { Text(t).font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit() }
    @ViewBuilder func big(_ emoji: String, _ line: String) -> some View {
        Text(emoji).font(.system(size: 56))
        Text(line).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    /// How today is going: one row per part of your life that has a daily aim, a dot per break aimed for.
    var today: some View {
        let cat = b.catalog()
        let names = cat.categories.keys.sorted().filter { c in (cat.categories[c]?.target ?? 0) > 0 && cat.activities.contains { $0.category == c && $0.off != true } }
        let last = b.today.last { $0.skipped != true }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TODAY SO FAR").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Text("\(b.blocksToday) of \(b.cap) blocks" + (b.streak > 1 ? " · \(b.streak)🔥" : "")).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }
            ForEach(b.lock == .reset && b.today.isEmpty ? [] : names, id: \.self) { c in
                let p = b.progress(c)
                HStack(spacing: 5) {
                    Text(pretty(c)).lineLimit(1)
                    Spacer()
                    ForEach(0..<min(p.aim, 6), id: \.self) { i in
                        Circle().fill(i < p.done ? b.tint(c) : Color.clear).overlay(Circle().stroke(i < p.done ? b.tint(c) : Color.secondary.opacity(0.6), lineWidth: 1.5))
                            .frame(width: 11, height: 11)
                    }
                    if p.done > p.aim { Text("+\(p.done - p.aim)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(b.tint(c)) }
                }
                .font(.system(size: 13, design: .rounded))
            }
            Group {
                if let x = last {
                    let a = cat.activities.first { $0.id == x.id }
                    let how = x.completed == true ? "" : (x.completed == false ? " (didn't)" : " (not answered yet)")
                    Text("Last break: \(a?.title ?? x.id), \(x.at.formatted(date: .omitted, time: .shortened))\(how)")
                } else { Text(b.lock == .reset ? "A day off. Nothing to keep count of." : "No breaks yet today.") }
            }
            .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).padding(.top, 4).lineLimit(2)
        }
    }

    static func ago(_ d: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d), to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return days == 0 ? "today" : "\(days)d"
    }
    var headline: String {
        switch b.stage {
        case .workReady: if case .reset? = b.lock { return "RESET DAY" }; return b.lock == nil ? "READY TO STEER THE AGENTS" : "DONE FOR TODAY"
        case .working: return "STEERING THE AGENTS"
        case .workPaused: return "PAUSED"
        case .onBreak: return "AWAY FROM THE SCREEN"
        case .morning: return "GOOD MORNING"
        case .choosing: return "BREAK TIME"
        case .breakDone: return "BREAK'S OVER"
        case .dayOff: return b.dayOffReason == .reset ? "RESET DAY" : "DONE FOR TODAY"
        case .evening: return "WORK'S DONE"
        }
    }
}

/// The house, in its own window: every room, most in need of attention first.
struct HouseView: View {
    @ObservedObject var b: Brain
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🏠 The house").font(.system(size: 18, weight: .heavy, design: .rounded))
            Text("Most in need of attention first. Rooms you rate rough come back sooner; the arrow shows whether a room is getting quicker.")
                .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(b.houseStats) { r in
                HStack(spacing: 6) {
                    Text(r.title).lineLimit(1)
                    Spacer()
                    if r.times == 0 { Text("not cleaned yet").foregroundStyle(.secondary) }
                    else {
                        Text(["", "✨ fine", "😐 meh", "🔥 rough"][r.mess ?? 0])
                        Text(r.avgMins.map { "\(Int($0.rounded()))m avg" } ?? "–").monospacedDigit().foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                        if let f = r.firstMins, let l = r.lastMins, r.times > 2 {
                            Text(l < f - 1 ? "↓" : (l > f + 1 ? "↑" : "→")).foregroundStyle(l < f - 1 ? Color.green : (l > f + 1 ? warm : .secondary))
                        }
                        Text(r.lastDone.map { Dashboard.ago($0) } ?? "").foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
                .font(.system(size: 13, design: .rounded))
            }
            if b.houseStats.isEmpty { Text("No rooms on your list yet.").font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary) }
        }
        .padding(22).frame(width: 400)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let brain = Brain()
    let ding = Ding()
    lazy var overlay = Overlay(app: self)
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var flashUntil: Date?

    var b: Brain { brain }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 2 {
            snapshot(CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2]); return
        }
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false; item.menu = menu
        _ = b.catalog()
        writeContext(); writeBriefPrompt()      // there from the first second, for the AI that's setting things up
        if sandbox == nil {
            ding.requestAccess { _ in self.ding.requestCalendar { self.writeContext(); self.writeBriefPrompt(); self.ensureBriefing() } }
        } else { ding.calAsked = true }     // a sandbox never asks for Calendar or Reminders
        startGuard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.ding.scheduleTonight([]) }   // removes old pre-planned blocks
        if b.setupDone { showDash() } else { showSettings() }
        let rebuild: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.overlay.rebuild() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: rebuild)
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main, using: rebuild)
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: rebuild)
        if CommandLine.arguments.contains("--test-ding") { testDing() }
        if CommandLine.arguments.contains("--house-selftest") { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.houseSelfTest() } }
        if CommandLine.arguments.contains("--preview-morning") { DispatchQueue.main.async { self.previewMorning() } }
        if CommandLine.arguments.contains("--go") { DispatchQueue.main.async { self.startWork() } }
        // `--spin-demo`: play the spin for real, full screen. It counts the frames drawn, then presses Reroll while
        // the reveal is still playing and "1 more minute" after it has gone still, with real mouse events, and
        // writes what happened to spin-demo.txt. Nothing is logged as a break.
        if CommandLine.arguments.contains("--spin-demo") {
            var out = ""
            func note(_ t: String) { out += t + "\n"; try? out.write(to: self.b.dir.appendingPathComponent("spin-demo.txt"), atomically: true, encoding: .utf8) }
            func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
            after(1.5) { self.b.lockOff = true; spinFrames = 0; self.beginChoosing() }
            after(8.6) {
                note("\(self.b.catalog().activities.count) activities · \(spinFrames) frames in \(String(format: "%.2f", self.demoDur)) s = \(Int(Double(spinFrames) / self.demoDur)) per second")
                note("reveal still playing: \(self.b.celebrating); pressed Reroll: \(self.demoClick("reroll"))")
            }
            after(9.0) { note("spinning again after Reroll: \(self.b.spinning)") }
            after(19.0) { note("reveal finished: \(!self.b.celebrating && self.b.act != nil); pressed 1 more minute: \(self.demoClick("snooze"))") }
            after(19.5) { note("back at work after 1 more minute: \(self.b.stage == .working)"); exit(0) }
        }
        if [.onBreak, .breakDone].contains(b.stage) { keepAwake(true); overlay.show() }
        if b.stage == .working { keepAwake(true) }
        if [.working, .workPaused].contains(b.stage), b.openWork == nil { openWorkSession() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        render()
    }

    /// `SpinBreak --snapshot <screen> out.png`: draws one screen into a PNG without putting anything on the display
    /// or starting the app's timers. For looking at a layout after changing it. Screens: dashboard, dashboard-working,
    /// spin, pick, break, done, done-chore, morning, review, preview, dayoff-reset, dayoff-capacity, evening,
    /// settings-activities, settings-balance, settings-schedule, settings-morning, settings-ai, settings-household.
    /// Nothing it sets up is saved. With an empty log it shows a made-up one, so the screens have something on them.
    func snapshot(_ what: String, to path: String) {
        let cat = b.catalog(), now = Date()
        let rooms = cat.activities.filter(Engine.isRoom)
        let walk = cat.activities.first { $0.category == "outdoors" } ?? cat.activities[0]
        if b.history.isEmpty {
            var h: [Done] = []
            for (i, a) in rooms.prefix(4).enumerated() {
                h.append(Done(id: a.id, category: a.category, at: now.addingTimeInterval(-Double(i + 1) * 86400), completed: true,
                              mins: [22.0, 15, 31, 12][i], mess: [3, 1, 2, 1][i]))
            }
            h.append(Done(id: walk.id, category: walk.category, at: now.addingTimeInterval(-5400), completed: true, note: "Loop around the block"))
            h.append(Done(id: cat.activities[2].id, category: cat.activities[2].category, at: now.addingTimeInterval(-1800), completed: true, note: "Good one"))
            b.history = h.sorted { $0.at < $1.at }
        }
        b.loadBriefing()
        var size = NSSize(width: 1728, height: 1117)
        // An optional last argument sets the screen size for the full-screen ones: --snapshot spin out.png 1440x900
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 3 {
            let wh = CommandLine.arguments[i + 3].split(separator: "x").compactMap { Double($0) }
            if wh.count == 2 { size = NSSize(width: wh[0], height: wh[1]) }
        }
        var view = AnyView(OverlayView(b: brain, app: self))
        switch what {
        case let t where t.hasPrefix("dashboard"):
            size = NSSize(width: 360, height: 620)
            switch t {
            case "dashboard-working": b.stage = .working; b.endAt = now.addingTimeInterval(222)
            case "dashboard-break": b.stage = .onBreak; b.act = walk; b.endAt = now.addingTimeInterval(b.breakLen)
            case "dashboard-ready": b.lockOff = true
            default: break
            }
            view = AnyView(Dashboard(b: brain, app: self))
        case "house": size = NSSize(width: 400, height: 330); view = AnyView(HouseView(b: brain))
        case let t where t.hasPrefix("spin"):
            // spin-box, spin-fast, spin-mid, spin-slow, spin-flash, spin-pop, spin (settled), spin-rare, spin-anchor, spin-small
            b.stage = .choosing; b.rerolls = 2
            var reel = Array(cat.activities.shuffled().prefix(t == "spin-small" ? 2 : 14))
            let rare = cat.activities.first { $0.weight <= 1.5 && !Engine.isRoom($0) }
            if t == "spin-rare", let rare { reel[min(4, reel.count - 1)] = rare }
            let idx = min(4, reel.count - 1), to = Double(3 * reel.count + idx), dur = 4.0
            b.reel = reel
            let at: [String: Double] = ["spin-fast": 0.25, "spin-mid": 1.6, "spin-slow": 3.3]
            if t == "spin-box" { b.reel = []; b.act = nil }
            else if let e = at[t] { b.reelAnim = (0, to, now.addingTimeInterval(-e), dur); b.spinning = true; b.act = nil }
            else {
                b.reelPos = to; b.act = reel[idx]; b.anchored = t == "spin-anchor"
                b.landedAt = now.addingTimeInterval(-(["spin-flash": 0.12, "spin-pop": 0.42][t] ?? 30))
            }
            view = AnyView(ZStack {
                LinearGradient(colors: [bgWork, Color(red: 0.05, green: 0.12, blue: 0.11)], startPoint: .top, endPoint: .bottom)
                SpinView(b: brain, app: self, now: now) {}
            }.foregroundStyle(.white))
        case "pick": b.stage = .choosing; view = AnyView(OverlayView(b: brain, app: self, picking: true))
        case "break": b.stage = .onBreak; b.act = walk; b.endAt = now.addingTimeInterval(b.breakLen); b.dingNote = "⌚ Your iPhone and Watch ding when it's over."
        case "done": b.stage = .breakDone; b.act = walk
        case "done-chore": b.stage = .breakDone; b.act = rooms.first ?? walk
        case "review": b.peek = .review
        case "preview": b.peek = .preview; b.checks = []
        case "dayoff-reset": b.stage = .dayOff; b.dayOffReason = .reset
        case "dayoff-capacity": b.stage = .dayOff; b.dayOffReason = .capacity(b.cap)
        case "evening": b.stage = .evening
        case let t where t.hasPrefix("settings"):
            size = NSSize(width: 880, height: 760)
            let m = settingsModel; m.sel = cat.activities.first?.id
            switch t {
            case "settings-activities": view = AnyView(ActivitiesTab(m: m))
            case "settings-balance": view = AnyView(BalanceTab(m: m))
            case "settings-schedule": view = AnyView(ScheduleTab(m: m, b: brain, app: self))
            case "settings-morning": view = AnyView(MorningTab(m: m))
            case "settings-household": view = AnyView(HouseholdTab(m: m, app: self))
            default: view = AnyView(AITab(m: m, b: brain, app: self))
            }
        default: b.stage = .morning
        }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13)).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua); w.backgroundColor = .windowBackgroundColor
        w.contentView = host; host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    func keepAwake(_ on: Bool) {
        if on, b.napGuard == nil {
            b.napGuard = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "SpinBreak timer")
        } else if !on, let g = b.napGuard { ProcessInfo.processInfo.endActivity(g); b.napGuard = nil }
    }

    func tick() {
        let sec = Int(Date().timeIntervalSince1970)
        // The brief doesn't need Calendar access, only an answer to the question (so the first one isn't written without your day in it).
        if sec % 60 == 0, ding.calAsked { ensureBriefing(); ensureEvening() }
        let left = b.endAt.timeIntervalSinceNow
        eveningGuard(); trackWork()
        if sec % 60 == 0 { refreshHousehold() }
        if sec % 3 == 0 { pickUpSetupFile(); pickUpRunNow() }
        if sec % 600 == 0, ding.calAsked { writeContext() }
        // The screen under a peek changed (work ran out, the break ended, the evening lock came up): that one wins.
        if b.peek != nil, b.stage != peekStage { closePeek() }
        if b.stage == .morning {
            if sec % 5 == 0, b.briefing == nil { b.loadBriefing() }
            if !overlay.windows.isEmpty { if b.awayUntil != nil { b.awayUntil = nil } }
            else if (b.awayUntil ?? .distantPast) < Date() { b.awayUntil = nil; overlay.show() }
        }
        // A new day wipes yesterday's leftovers (a paused timer, an unanswered break, last night's lock screen),
        // otherwise the morning screen below never gets its turn.
        if !b.morningDone, Calendar.current.component(.hour, from: Date()) >= 5, b.peek == nil,
           [.working, .workPaused, .breakDone, .dayOff, .evening, .choosing].contains(b.stage),
           !Calendar.current.isDateInToday(b.endAt) {
            overlay.hide(); keepAwake(false); b.stage = .workReady; b.remaining = b.workLen; b.act = nil; b.persist()
        }
        // A new workday opens on the morning screen by itself; you don't have to press Start to find it.
        if b.stage == .workReady, b.setupDone, !b.morningDone, b.lock == nil, b.peek == nil, Calendar.current.component(.hour, from: Date()) >= 5 {
            b.checks = b.savedChecks; b.loadBriefing(); b.stage = .morning; overlay.show(); render()
        }
        switch b.stage {
        case .working:
            let warnAt = min(30, b.workLen * 0.1)
            if !b.warned && left <= warnAt && left > 0 {
                b.warned = true; sound("Ping"); flashUntil = Date().addingTimeInterval(warnAt)
            }
            // In a meeting: no spin over it. The block just keeps running (and logging) until the meeting ends.
            if left <= 0, b.lock == nil, let m = ding.meetingNow() {
                b.endAt = m.endDate.addingTimeInterval(60); b.warned = true; b.persist(); render()
                return
            }
            if left <= 0 {
                // Past the end of the workday: no more agent check-ins, straight to tonight's plan.
                if b.lock == .evening { showDayOff(.evening) } else { beginChoosing() }
            }
        case .onBreak:
            if left <= 0 { b.stage = .breakDone; b.persist(); sound("Hero"); overlay.show() }
        default: break
        }
        render()
    }

    // MARK: flow (every transition waits for you)

    @objc func startWork() {
        guard [.workReady, .workPaused].contains(b.stage) else { return }
        if b.stage == .workReady {
            if let l = b.lock { showDayOff(l); return }
            if !b.morningDone { b.checks = b.savedChecks; b.stage = .morning; overlay.show(); render(); return }
        }
        b.endAt = Date().addingTimeInterval(b.stage == .workPaused ? b.remaining : b.workLen)
        if b.openWork == nil { openWorkSession() }
        b.stage = .working; b.warned = false; keepAwake(true); b.persist(); render()
    }
    @objc func pauseWork() {
        guard b.stage == .working else { return }
        if let i = b.openWork { b.work[i].pauses += 1; b.saveWork() }
        b.remaining = max(0, b.endAt.timeIntervalSinceNow); b.stage = .workPaused; keepAwake(false); b.persist(); render()
    }
    @objc func reset() {
        closeWorkSession(); b.cancelDing(ding); overlay.hide(); keepAwake(false); b.spinning = false
        b.stage = .workReady; b.act = nil; b.remaining = b.workLen; b.persist(); render()
    }
    @objc func breakNow() { beginChoosing() }

    // MARK: work log (computer time, on the "SpinBreak Work" calendar)

    var lastActive = Date(), lastWorkTrack = Date.distantPast
    func openWorkSession() {
        var s = WorkSession(start: Date(), planned: Double(b.workMin))
        s.eventID = ding.workEvent("💻 At the computer", from: s.start, to: s.start.addingTimeInterval(b.workLen))
        b.work.append(s); b.saveWork()
    }
    /// Ends the open session at the last moment you were actually at the Mac (sleep and idle don't count).
    func closeWorkSession(at t: Date? = nil) {
        guard let i = b.openWork else { return }
        let end = max(b.work[i].start.addingTimeInterval(60), min(Date(), t ?? lastActive.addingTimeInterval(30)))
        b.work[i].end = end; let s = b.work[i]
        let mins = Int(s.mins.rounded()), over = Int(s.over.rounded())
        let title = "💻 Computer · \(Brain.hm(mins))" + (over >= 1 ? " (+\(over) over)" : "")
        let notes = "Planned \(Int(s.planned)) min, actually \(mins) min." + (s.pauses > 0 ? " Paused \(s.pauses)×." : "")
        ding.updateEvent(s.eventID, title: title, notes: notes, end: end)
        b.saveWork()
    }
    /// Twice a minute: note whether you're at the Mac, stretch the calendar block while you keep going,
    /// and close it once you've walked away from a paused timer.
    func trackWork() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < 60 { lastActive = Date() }
        guard Date().timeIntervalSince(lastWorkTrack) > 30, let i = b.openWork else { return }
        lastWorkTrack = Date()
        if b.work[i].eventID == nil, ding.calOK {   // calendar access arrives a beat after launch
            let s = b.work[i]
            b.work[i].eventID = ding.workEvent("💻 At the computer", from: s.start, to: max(Date(), s.start.addingTimeInterval(s.planned * 60)))
            b.saveWork()
        }
        switch b.stage {
        case .working, .workPaused:
            if idle > 300 { closeWorkSession(at: Date().addingTimeInterval(-idle)); return }
            let s = b.work[i]
            if Date() > s.start.addingTimeInterval(s.planned * 60) { ding.updateEvent(s.eventID, end: Date().addingTimeInterval(60)) }
        default: closeWorkSession()
        }
    }

    /// After the workday, the laptop belongs to the evening plan. If you're on it, it shows you where you should be.
    func eveningGuard() {
        let evening = b.lock == .evening
        if b.stage == .evening {
            if !evening { overlay.hide(); b.stage = .workReady; render(); return }
            refreshEvening(); return
        }
        guard evening, b.eveningLock, b.setupDone, b.stage == .workReady else { return }
        if let u = b.eveUnlockedUntil, u.timeIntervalSinceNow > 0 { return }
        refreshEvening(); b.stage = .evening; sound("Glass"); overlay.show(); render()
    }
    /// The evening screen has no plan of its own any more; it just says the day is done.
    func refreshEvening() { b.eveNow = nil; b.eveNext = nil }
    func eveningUnlock() { b.eveUnlockedUntil = Date().addingTimeInterval(10 * 60); overlay.hide(); b.stage = .workReady; render() }

    func showDayOff(_ l: DayLock) {
        b.dayOffReason = l
        keepAwake(false); b.stage = .dayOff; sound("Glass"); overlay.show(); render()
    }

    // MARK: household + your own AI

    func refreshHousehold() {
        let h = ding.household(b.catalog())
        b.household = h.entries; b.houseLive = h.live
    }

    /// An AI with file access saved setup.json in the SpinBreak folder: import it, show what changed, and answer
    /// in setup-status.json so the AI can check its own work.
    func pickUpSetupFile() {
        let f = b.dir.appendingPathComponent("setup.json"), fm = FileManager.default
        // Still being written? Wait until the file has sat untouched for a couple of seconds.
        guard let at = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date, Date().timeIntervalSince(at) > 2,
              let text = try? String(contentsOf: f, encoding: .utf8) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        var status: [String: Any]
        do {
            let x = try AISetup.parse(text)
            AISetup.apply(x, to: b)
            try? fm.moveItem(at: f, to: b.dir.appendingPathComponent("setup.imported-\(stamp).json"))
            settingsModel.reload(); settingsModel.importMsg = "✅ Your AI saved your setup: \(x.summary)."
            if let p = x.place { settingsModel.place = p; settingsModel.findPlace { _ in self.writeContext(); self.writeBriefPrompt() } }
            status = ["ok": true, "summary": x.summary]
        } catch {
            try? fm.moveItem(at: f, to: b.dir.appendingPathComponent("setup.failed-\(stamp).json"))
            settingsModel.importMsg = "⚠️ Your AI saved a setup.json I couldn't use: \(error.localizedDescription)"
            status = ["ok": false, "error": error.localizedDescription]
        }
        status["at"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: b.dir.appendingPathComponent("setup-status.json"), options: .atomic)
        }
        writeContext(); writeBriefPrompt()
        settingsModel.tab = 4; showSettings(); settingsChanged()
    }

    /// `touch brief.run-now` in the SpinBreak folder: write today's brief right now. This is how the AI that
    /// set the writer up proves it works from inside the app, where it will run every morning.
    func pickUpRunNow() {
        guard !b.briefRunning, !eveningRunning else { return }
        let fm = FileManager.default, f = b.dir.appendingPathComponent("brief.run-now"), e = b.dir.appendingPathComponent("brief-evening.run-now")
        if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f); ensureBriefing(force: true) }
        else if fm.fileExists(atPath: e.path) { try? fm.removeItem(at: e); ensureEvening(force: true) }
    }

    /// Pretends to be the other person for a moment: claims a room as someone else, reads it back, cleans up.
    func houseSelfTest() {
        var log: [String] = []
        let cal = ding.makeHomeCalendar(); log.append("calendar: \(cal?.title ?? "nil") on \(cal?.source.title ?? "-")")
        if let cal, let room = b.catalog().activities.first(where: Engine.isRoom) {
            let e = EKEvent(eventStore: ding.ek); e.calendar = cal; e.title = "selftest"; e.startDate = Date().addingTimeInterval(-300); e.endDate = Date().addingTimeInterval(1200)
            var c = URLComponents(); c.scheme = "spinbreak"; c.host = "room"
            c.queryItems = [.init(name: "id", value: "kitchen-x"), .init(name: "name", value: room.name), .init(name: "by", value: "selftest"), .init(name: "who", value: "Tester"), .init(name: "state", value: "claimed")]
            e.url = c.url
            do { try ding.ek.save(e, span: .thisEvent, commit: true) } catch { log.append("save failed: \(error)") }
            let mine = ding.claimRoom(room, until: Date().addingTimeInterval(600))
            ding.ek.reset()
            let h = ding.household(b.catalog())
            log.append("read back: \(h.entries.map { "\($0.id) \($0.note ?? "")" }) live: \(h.live.map { "\($0.who): \($0.room)" })")
            let d = Engine.draw(b.catalog(), history: b.history, now: Date(), reroll: true, household: h.entries)
            log.append("expected room blocked: \(room.id); draw pool has it: \(d.pool.contains { $0.id == room.id })")
            for id in [e.eventIdentifier, mine].compactMap({ $0 }) { if let x = ding.ek.event(withIdentifier: id) { try? ding.ek.remove(x, span: .thisEvent, commit: true) } }
            log.append("own claim id: \(mine ?? "nil") (skipped on read as mine)")
        }
        try? log.joined(separator: "\n").write(to: b.dir.appendingPathComponent("house-selftest.txt"), atomically: true, encoding: .utf8)
    }

    /// Today's request for the person's own AI: their brief instructions plus today's context.json.
    @objc func copyBriefRequest() {
        writeContext()
        let ctx = (try? String(contentsOf: b.dir.appendingPathComponent("context.json"), encoding: .utf8)) ?? "{}"
        let text = AISetup.briefRequest(brief: b.briefStyle, context: ctx, name: b.d.string(forKey: "personName") ?? "")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        b.briefMsg = "Copied. Paste it into your AI, then copy its answer and press Paste brief."
    }
    @objc func pasteBrief() {
        guard var t = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), t.count > 40 else {
            b.briefMsg = "Nothing to paste yet. Copy your AI's answer first."; return
        }
        if t.hasPrefix("```") { t = t.components(separatedBy: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n") }
        if t.contains("Today's data from SpinBreak") { b.briefMsg = "That's the request, not the answer. Paste it into your AI first."; return }
        try? t.write(to: b.briefingURL, atomically: true, encoding: .utf8)
        b.loadBriefing(); b.briefMsg = ""
    }
    /// Go get the brief from your AI and come back; the morning screen returns by itself.
    func stepAway() { copyBriefRequest(); b.awayUntil = Date().addingTimeInterval(180); overlay.hide(); render() }
    /// "I need the laptop for 5 minutes": the morning screen steps aside, keeps your ticks, and comes back.
    func lookAway() { b.awayUntil = Date().addingTimeInterval(5 * unit); overlay.hide(); render() }

    // MARK: the morning screen again (after skipping it, on a day off, or as a preview)

    var peekStage = Stage.workReady
    /// Today's brief and checklist, over whatever is going on. The timer underneath keeps running.
    @objc func showMorningAgain() {
        if b.stage == .morning { overlay.show(); return }
        b.checks = b.savedChecks; b.loadBriefing(); peekStage = b.stage; b.peek = .review; overlay.show(); render()
    }
    /// Shows a blank morning screen (checklist + briefing) without touching today's state.
    @objc func previewMorning() {
        if b.stage == .morning { overlay.show(); return }
        b.loadBriefing(); peekStage = b.stage; b.peek = .preview; b.checks = []; overlay.show(); render()
    }
    func closePeek() {
        guard b.peek != nil else { return }
        b.checks = b.savedChecks      // a preview's ticks aren't kept; a review's already are
        b.peek = nil
        if [.choosing, .onBreak, .breakDone, .morning, .dayOff, .evening].contains(b.stage) { overlay.show() } else { overlay.hide() }
        render()
    }

    // MARK: the daily brief
    // SpinBreak is the scheduler. Each morning it refreshes context.json and brief-prompt.md, then runs the brief
    // writer: brief.sh in the SpinBreak folder, which the AI that set the app up wrote. It retries a few times,
    // and says how each run went in brief-status.json.

    var briefingRunning: Bool { get { b.briefRunning } set { b.briefRunning = newValue } }
    func writeContext() {
        let cal = Calendar.current, t = DateFormatter(); t.timeStyle = .short
        let sun = Engine.sunOnHouse(on: Date(), b.catalog(), cal)
        func hm(_ h: Double) -> String { t.string(from: cal.startOfDay(for: Date()).addingTimeInterval(h * 3600)) }
        let cat = b.catalog()
        let yesterday = b.history.filter { cal.isDateInYesterday($0.at) }.map { x -> [String: String] in
            let a = cat.activities.first { $0.id == x.id }
            return ["time": t.string(from: x.at), "activity": a?.title ?? x.id,
                    "result": x.skipped == true ? "already done" : (x.completed == true ? "did it" : (x.completed == false ? "didn't" : "unknown")),
                    "note": x.note ?? ""]
        }
        let todayLog = b.history.filter { cal.isDateInToday($0.at) }.map { x -> [String: String] in
            let a = cat.activities.first { $0.id == x.id }
            return ["time": t.string(from: x.at), "activity": a?.title ?? x.id,
                    "result": x.skipped == true ? "already done" : (x.completed == true ? "did it" : (x.completed == false ? "didn't" : "unknown")),
                    "note": x.note ?? "", "mins": x.mins.map { String(Int($0.rounded())) } ?? "", "mess": x.mess.map { ["", "fine", "meh", "rough"][$0] } ?? ""]
        }
        let weekAgo = Date().addingTimeInterval(-7 * 86400).timeIntervalSinceReferenceDate
        let week = b.history.filter { $0.at.timeIntervalSinceReferenceDate > weekAgo && $0.completed == true }
        let workouts = week.filter { $0.id == "workout" }.count
        let outside = week.filter { $0.category == "outdoors" }.count * b.breakMin
        let (full, total) = Engine.fullDaysThisWeek(b.history, now: Date(), cap: b.cap, workdays: b.workdays)
        let f = DateFormatter(); f.dateStyle = .full
        let ctx: [String: Any] = [
            "today": f.string(from: Date()), "date": Brain.dayKey(), "place": b.d.string(forKey: "placeName") ?? "",
            "morningChecklist": b.checklist, "alreadyUsed": Brief.alreadyUsed(in: b.dir),
            "sunOnHouse": hm(sun.rise), "sunLeavesHouse": hm(sun.set),
            "isResetDay": !b.workdays.contains(cal.component(.weekday, from: Date())),
            "eventsToday": ding.eventsToday(), "yesterdayLog": yesterday, "todayLog": todayLog,
            "eventsTomorrow": ding.eventsToday(dayOffset: 1),
            "sunOnHouseTomorrow": hm(Engine.sunOnHouse(on: Date().addingTimeInterval(86400), b.catalog(), cal).rise),
            "house": b.houseStats.map { r -> [String: Any] in
                ["room": r.title, "timesDone": r.times, "avgMinutes": r.avgMins.map { Int($0.rounded()) } ?? NSNull(),
                 "firstMinutes": r.firstMins.map { Int($0.rounded()) } ?? NSNull(), "latestMinutes": r.lastMins.map { Int($0.rounded()) } ?? NSNull(),
                 "lastMess": r.mess.map { ["", "fine", "meh", "rough"][$0] } ?? "not rated", "roughTimes": r.roughCount,
                 "lastDone": r.lastDone.map { Dashboard.ago($0) } ?? "never"] },
            "computerToday": [
                "minutes": Int(b.workToday.reduce(0) { $0 + $1.mins }.rounded()), "blocks": b.workToday.count,
                "ranLong": b.workToday.filter { $0.over >= 1 }.count, "extraMinutes": Int(b.workToday.reduce(0) { $0 + $1.over }.rounded()),
                "sessions": b.workToday.map { "\(t.string(from: $0.start))–\(t.string(from: $0.end ?? Date())) (\(Int($0.mins.rounded())) min, planned \(Int($0.planned)))" }],
            "household": b.household.filter { $0.note != "household" || $0.completed == true }.map { x -> [String: String] in
                ["room": cat.activities.first { $0.id == x.id }?.title ?? x.id, "when": t.string(from: x.at) + " " + Dashboard.ago(x.at),
                 "state": x.note == "live" ? "being cleaned right now" : "cleaned", "mess": x.mess.map { ["", "fine", "meh", "rough"][$0] } ?? ""] },
            "name": b.d.string(forKey: "personName") ?? Household.name,
            "thisWeek": ["workoutsDone": workouts, "minutesOutside": outside, "outsideGoal": 120,
                         "fullWorkdays": "\(full)/\(total)", "dailyCapacityBlocks": b.cap],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: ctx, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: b.dir.appendingPathComponent("context.json"), options: .atomic)
        }
    }

    /// The writer SpinBreak runs: brief.sh in the SpinBreak folder, which the AI that set the app up wrote.
    var briefScript: URL? { FileManager.default.fileExists(atPath: b.briefJobURL.path) ? b.briefJobURL : nil }

    /// The instructions brief.sh runs on, rewritten before every run with today's data inside them: your brief
    /// instructions and context.json. The writer needs no access to your files. The same prompt file serves the
    /// morning brief and (when you've set one up) the evening one.
    func writeBriefPrompt(evening: Bool = false) {
        func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
        let name = b.d.string(forKey: "personName") ?? "", place = b.d.string(forKey: "placeName")
        let context = text(b.dir.appendingPathComponent("context.json")) ?? "{}"
        let prompt = evening ? Brief.eveningPrompt(name: name, place: place, style: text(b.eveningStyleURL) ?? "", context: context, morning: text(b.briefingURL))
                             : Brief.jobPrompt(name: name, place: place, style: b.briefStyle, context: context)
        try? prompt.write(to: b.dir.appendingPathComponent("brief-prompt.md"), atomically: true, encoding: .utf8)
    }

    func saveBriefStatus(_ st: BriefStatus) {
        b.briefStatus = st
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(st).write(to: b.briefStatusURL, options: .atomic)
    }

    /// Runs brief.sh for the morning or evening brief, off the main thread's back. `done` gets true only if the
    /// brief file was actually written during this run. One run at a time: they share the prompt and the log.
    func runWriter(_ script: URL, evening: Bool, done: @escaping (Bool) -> Void) {
        let fm = FileManager.default, out = evening ? b.eveningURL : b.briefingURL, started = Date()
        writeContext(); writeBriefPrompt(evening: evening)
        var st = BriefStatus(state: "running", kind: evening ? "evening" : "morning", started: started, brief: out.path)
        saveBriefStatus(st)
        // Run it from the folder, with a PATH a login shell would have, and keep what it says.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = [script.path]
        p.currentDirectoryURL = b.dir
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"].joined(separator: ":")
        env["SPINBREAK_DIR"] = b.dir.path; env["SPINBREAK_OUT"] = out.path; env["SPINBREAK_KIND"] = st.kind
        p.environment = env
        // What it prints is the brief (kept in brief.out); anything it complains about goes to brief.log.
        let log = b.dir.appendingPathComponent("brief.log"), printed = b.dir.appendingPathComponent("brief.out")
        fm.createFile(atPath: log.path, contents: nil); fm.createFile(atPath: printed.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: printed) { p.standardOutput = h }
        if let h = try? FileHandle(forWritingTo: log) { p.standardError = h }
        p.standardInput = FileHandle.nullDevice
        var timedOut = false
        p.terminationHandler = { proc in DispatchQueue.main.async {
            // The brief is what the writer printed. (An older brief.sh that wrote the file itself still counts.)
            var wrote = ((try? fm.attributesOfItem(atPath: out.path))?[.modificationDate] as? Date).map { $0 >= started.addingTimeInterval(-1) } ?? false
            if !wrote, let text = (try? String(contentsOf: printed, encoding: .utf8)).flatMap(Brief.extract) {
                wrote = (try? text.write(to: out, atomically: true, encoding: .utf8)) != nil
            }
            let size = ((try? fm.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
            st.finished = Date(); st.state = wrote && size > 40 ? "ok" : "failed"
            if st.state == "failed" {
                st.detail = timedOut ? "it ran for more than 10 minutes and was stopped"
                    : proc.terminationStatus != 0 ? "\(script.lastPathComponent) exited with code \(proc.terminationStatus)"
                    : "\(script.lastPathComponent) didn't print a brief (what it printed is in brief.out)"
            }
            // The prompt file goes back to the morning's, which is what anyone reading the folder expects to find.
            if evening { self.writeBriefPrompt() }
            self.saveBriefStatus(st); done(st.state == "ok")
        } }
        do { try p.run() } catch {
            st.finished = Date(); st.state = "failed"; st.detail = "couldn't start \(script.lastPathComponent): \(error.localizedDescription)"
            saveBriefStatus(st); done(false); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { if p.isRunning { timedOut = true; p.terminate() } }
    }

    /// Each day after 5 am (or on demand), have the writer write the briefing. Never blocks the app.
    /// No brief after a run? It tries again, up to three times a day, 20 minutes apart: the Mac may have woken
    /// without a network, or the AI may have been down for a minute.
    var lastBriefTry = Date.distantPast
    func ensureBriefing(force: Bool = false) {
        b.loadBriefing()
        guard !briefingRunning, !eveningRunning, force || b.briefing == nil, let script = briefScript else { return }
        guard force || Calendar.current.component(.hour, from: Date()) >= 5 else { return }
        let day = Brain.dayKey(), tries = b.d.string(forKey: "briefTryDay") == day ? b.d.integer(forKey: "briefTries") : 0
        guard force || (tries < 3 && Date().timeIntervalSince(lastBriefTry) > 20 * 60) else { return }
        if !force { b.d.set(day, forKey: "briefTryDay"); b.d.set(tries + 1, forKey: "briefTries"); lastBriefTry = Date() }
        briefingRunning = true
        runWriter(script, evening: false) { _ in self.briefingRunning = false; self.b.loadBriefing() }
    }
    @objc func rewriteBriefing() { ensureBriefing(force: true) }

    var eveningRunning = false
    /// Once work ends, the same writer does an evening brief for the lock screen, if you've set one up
    /// (brief-style-evening.md says how you want it).
    func ensureEvening(force: Bool = false) {
        guard b.hasEveningBrief, let script = briefScript else { return }
        b.loadEvening()
        guard !eveningRunning, !briefingRunning, force || b.eveningBriefing == nil, force || b.lock == .evening else { return }
        guard force || b.d.string(forKey: "eveningTried") != Brain.dayKey() else { return }
        b.d.set(Brain.dayKey(), forKey: "eveningTried")
        eveningRunning = true
        runWriter(script, evening: true) { _ in self.eveningRunning = false; self.b.loadEvening() }
    }
    @objc func rewriteEvening() { ensureEvening(force: true) }

    func morningPassed() {
        guard b.stage == .morning else { return }
        b.morningDone = true; b.awayUntil = nil; overlay.hide(); b.stage = .workReady; startWork()
    }
    func closeDay() {
        overlay.hide(); b.stage = .workReady; b.persist(); render()
    }
    func overrideDay() { b.overridden = true; overlay.hide(); b.stage = .workReady; startWork() }

    // MARK: focus guard: during work, only allowlisted apps may come forward. Everything else gets hidden.

    func startGuard() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.police(app)
        }
    }

    var guarding: Bool {
        b.focusGuard && b.morningDone && b.lock == nil && [.workReady, .working, .workPaused].contains(b.stage)
    }

    func police(_ app: NSRunningApplication) {
        guard guarding, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular else { return }
        let ok = b.allowlist().contains { $0.hasSuffix("*") ? id.hasPrefix(String($0.dropLast())) : $0 == id }
        guard !ok else { return }
        app.hide()
        sound("Funk")
        blockedUntil = Date().addingTimeInterval(2.5); blocked = app.localizedName ?? id; render()
    }
    var blocked = ""
    var blockedUntil: Date?

    func beginChoosing() {
        flashUntil = nil; closeWorkSession()
        b.stage = .choosing; b.act = nil; b.rerolls = 2; b.persist()
        sound("Glass"); overlay.show(); render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.spin(reroll: false) }
    }

    var demoDur = 4.0
    /// A real click (mouse down, mouse up) on one of the spin's buttons, through the window like any other.
    func demoClick(_ name: String) -> Bool {
        guard let f = demoFrames[name], let w = overlay.windows.first, let v = w.contentView else { return false }
        let p = NSPoint(x: f.midX, y: v.bounds.height - f.midY)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            w.sendEvent(e)
        }
        return true
    }
    func spin(reroll: Bool) {
        guard b.stage == .choosing, !b.spinning else { return }
        if reroll { guard b.rerolls > 0 else { return }; b.rerolls -= 1 }
        refreshHousehold()
        let draw = Engine.draw(b.catalog(), history: b.history, now: Date(), avoid: b.act?.id, reroll: reroll, household: b.household)
        // Winner chosen first; the reel shows it plus a sample of other eligible options.
        var slices = Array(draw.pool.filter { $0.id != draw.pick.id }.shuffled().prefix(15))
        // The reel runs the height of the screen, so a thin pool is topped up with the rest of your list (it's the
        // show, not the draw: the winner is already chosen), and only then with "your call".
        let shown = Set(slices.map(\.id) + [draw.pick.id])
        slices += b.catalog().activities.filter { $0.off != true && $0.afterDay != true && !shown.contains($0.id) }.shuffled().prefix(max(0, 14 - slices.count))
        while slices.count < 6 { slices.append(Engine.freeChoice) }
        let pickIndex = Int.random(in: 0...slices.count)
        slices.insert(draw.pick, at: pickIndex)
        let n = slices.count
        let to = Double(Int.random(in: 3...4) * n + pickIndex)
        let dur = Double.random(in: 3.6...4.6)
        b.reel = slices; b.reelPos = 0; demoDur = dur
        b.reelAnim = (0, to, Date(), dur)
        b.spinning = true; b.act = nil; b.landedAt = nil; b.celebrating = false
        // One tick per row passing the window, matching the visual easing.
        var lastT = -1.0; let rows = Int(to)
        for j in 1...max(1, rows) {
            let tt = (1 - pow(1 - Double(j) / Double(rows), 1.0 / 3)) * dur
            if tt - lastT < 0.05 { continue }; lastT = tt
            DispatchQueue.main.asyncAfter(deadline: .now() + tt) { if self.b.spinning { self.sound("Tink", restart: true) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) {
            guard self.b.stage == .choosing else { return }
            self.b.reelPos = to; self.b.reelAnim = nil
            self.b.anchored = draw.anchored; self.b.act = draw.pick; self.b.spinning = false
            let at = Date(); self.b.landedAt = at; self.b.celebrating = true
            self.sound(draw.anchored ? "Hero" : "Purr"); self.b.persist()
            // The reveal plays for a couple of seconds, then the screen goes still.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { if self.b.landedAt == at { self.b.celebrating = false } }
        }
    }

    func snooze() {
        guard !b.snoozed else { return }
        b.snoozed = true; overlay.hide()
        b.stage = .working; b.warned = true; b.endAt = Date().addingTimeInterval(60); b.persist(); render()
    }

    func goBreak() {
        guard let a = b.act, b.stage == .choosing, !b.spinning else { return }
        let started = Done(id: a.id, category: a.category, at: Date(), completed: nil)
        b.history.append(started); b.saveHistory()
        var end = Date().addingTimeInterval(b.breakLen)
        let pastEnd = Calendar.current.component(.hour, from: Date().addingTimeInterval(b.breakLen)) >= b.workEnd
        var title = pastEnd ? "🌙 \(a.emoji) done. Open the laptop one last time for tonight's plan." : "⏰ Back to the computer (\(a.emoji) break over)"
        var meetingNote = ""
        // A meeting before the break would end? Come back 2 minutes before it starts.
        if let m = ding.nextMeeting(before: end.addingTimeInterval(120)) {
            end = max(Date().addingTimeInterval(5 * unit), m.startDate.addingTimeInterval(-2 * unit))
            let t = DateFormatter(); t.timeStyle = .short
            title = "📅 Back for \(m.title ?? "your meeting") at \(t.string(from: m.startDate))"
            meetingNote = "📅 Shortened for \(m.title ?? "a meeting") at \(t.string(from: m.startDate)). "
        }
        b.stage = .onBreak; b.endAt = end; b.snoozed = false
        b.dingNote = "⌚ Setting up your watch ding…"
        b.eventID = ding.breakEvent("\(a.emoji) \(a.name)", notes: a.how, from: Date(), to: end)
        b.houseEventID = ding.claimRoom(a, until: end)
        b.persist(); keepAwake(true); render()
        // Buzz the wrist now with what you're doing: a reminder that fires at once and clears itself two minutes later.
        let tf = DateFormatter(); tf.timeStyle = .short
        ding.schedule(at: Date().addingTimeInterval(2), title: "\(a.emoji) \(a.name) · until \(tf.string(from: end))") { id, _ in
            if let id { DispatchQueue.main.asyncAfter(deadline: .now() + 120) { self.ding.cancel(id) } }
        }
        ding.schedule(at: b.endAt, title: title) { id, note in
            self.b.reminderID = id; self.b.dingNote = meetingNote + note; self.b.persist()
        }
    }

    func markLast(_ didIt: Bool) {
        let note = b.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = b.history.lastIndex(where: { $0.skipped != true }), b.history[i].completed == nil {
            b.history[i].completed = didIt; if !note.isEmpty { b.history[i].note = note }
            if let m = b.mess { b.history[i].mess = m }
            if didIt && b.history[i].mins == nil { b.history[i].mins = max(0, min(Date(), b.endAt).timeIntervalSince(b.history[i].at)) / 60 }
            b.saveHistory()
        }
        if let a = b.act, b.houseEventID != nil { ding.settleRoom(b.houseEventID, a, didIt: didIt, mess: b.mess); b.houseEventID = nil }
        b.note = ""; b.mess = nil
    }

    /// "That room is spotless": log it so it won't come up again this week, then spin again for free.
    func alreadyDone() {
        guard let a = b.act, b.stage == .choosing, !b.spinning else { return }
        let x = Done(id: a.id, category: a.category, at: Date(), completed: nil, note: "already done", skipped: true)
        b.history.append(x); b.saveHistory()
        _ = ding.claimRoom(a, until: Date().addingTimeInterval(60), state: "spotless")
        spin(reroll: false)
    }

    /// Finished before the timer: record how long it really took (chore times get tracked this way).
    func finishEarly() {
        guard b.stage == .onBreak, let i = b.history.lastIndex(where: { $0.skipped != true }) else { return }
        b.history[i].mins = Date().timeIntervalSince(b.history[i].at) / 60; b.saveHistory()
        b.cancelDing(ding); b.endAt = Date(); b.stage = .breakDone; b.persist(); sound("Hero"); render()
    }

    /// The chore is bigger than 25 minutes: keep going and keep the clock honest.
    func extendBreak() {
        guard b.stage == .onBreak, let a = b.act else { return }
        b.endAt = max(b.endAt, Date()).addingTimeInterval(10 * 60)
        ding.cancel(b.reminderID); b.reminderID = nil
        if let id = b.eventID { ding.moveEventEnd(id, to: b.endAt) }
        ding.schedule(at: b.endAt, title: "⏰ Back to the computer (\(a.emoji) +10 done)") { id, note in
            self.b.reminderID = id; self.b.dingNote = "➕ Extended. " + note; self.b.persist()
        }
        b.persist(); render()
    }

    func unlock() {
        markLast(false); b.cancelDing(ding); overlay.hide(); keepAwake(false)
        b.stage = .workReady; b.act = nil; b.remaining = b.workLen; b.persist(); render()
    }

    func finishBreak(didIt: Bool) {
        markLast(didIt); b.cancelDing(ding); overlay.hide()
        b.stage = .workReady; b.act = nil; b.persist()
        startWork()
    }

    @objc func testDing() {
        ding.schedule(at: Date().addingTimeInterval(60), title: "🧪 SpinBreak test ding") { _, note in
            let a = NSAlert(); a.messageText = "Watch ding test"
            a.informativeText = note.replacingOccurrences(of: "dings at", with: "should ding at")
                + "\n\nIf your watch doesn't buzz within about a minute, open Reminders on your iPhone and check that the SpinBreak list exists."
            NSApp.activate(ignoringOtherApps: true); a.runModal()
        }
    }

    // MARK: output

    func sound(_ name: String, restart: Bool = false) {
        guard let s = NSSound(named: NSSound.Name(name)) else { return }
        if restart { s.stop() }; s.play()
    }

    func fmt(_ t: TimeInterval) -> String { let s = max(0, Int(t.rounded(.up))); return String(format: "%d:%02d", s / 60, s % 60) }

    func render() {
        let left = b.endAt.timeIntervalSinceNow
        var title: String
        switch b.stage {
        case .workReady: title = "🍅 Go"
        case .working: title = "🍅 " + fmt(left)
        case .workPaused: title = "🍅 ⏸ " + fmt(b.remaining)
        case .choosing: title = "🎡"
        case .onBreak: title = "\(b.act?.emoji ?? "☕") " + fmt(left)
        case .breakDone: title = "👋 Back?"
        case .morning: title = b.awayUntil.map { "☀️ " + fmt($0.timeIntervalSinceNow) } ?? "☀️"
        case .dayOff: title = b.dayOffReason == .reset ? "🌲" : "🌙"
        case .evening: title = "🌙"
        }
        if b.stage == .workReady, let l = b.lock { title = l == .reset ? "🌲 Reset day" : "🌙 Done" }
        if let f = blockedUntil, f.timeIntervalSinceNow > 0 {
            title = "🚫 \(blocked): not now"
        }
        else if let f = flashUntil, f.timeIntervalSinceNow > 0, b.stage == .working, Int(Date().timeIntervalSince1970 * 2) % 2 == 0 {
            title = "⏳ Wrap up!"
        }
        item.button?.title = title
        // Dock badge = the countdown, visible even with the menu bar hidden.
        switch b.stage {
        case .working: NSApp.dockTile.badgeLabel = fmt(left)
        case .workPaused: NSApp.dockTile.badgeLabel = "⏸"
        case .onBreak: NSApp.dockTile.badgeLabel = fmt(left)
        case .workReady: NSApp.dockTile.badgeLabel = b.lock == nil ? "Go" : nil
        default: NSApp.dockTile.badgeLabel = nil
        }
    }

    // MARK: Dock + dashboard window

    lazy var dash: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "SpinBreak"; w.isReleasedWhenClosed = false; w.center()
        w.contentView = NSHostingView(rootView: Dashboard(b: brain, app: self))
        return w
    }()
    @objc func showDash() { NSApp.activate(ignoringOtherApps: true); dash.makeKeyAndOrderFront(nil) }
    lazy var houseWin: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "The House"; w.isReleasedWhenClosed = false; w.center()
        w.contentView = NSHostingView(rootView: HouseView(b: brain))
        return w
    }()
    @objc func showHouse() { NSApp.activate(ignoringOtherApps: true); houseWin.makeKeyAndOrderFront(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if [.choosing, .onBreak, .breakDone, .morning, .dayOff].contains(b.stage) { overlay.show() } else { showDash() }
        return true
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu(); m.autoenablesItems = false; menuNeedsUpdate(m); return m
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    static let icon: NSImage = {
        let img = NSImage(size: NSSize(width: 512, height: 512)); img.lockFocus()
        NSColor(red: 0.08, green: 0.07, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 432, height: 432), xRadius: 96, yRadius: 96).fill()
        ("🍅" as NSString).draw(at: NSPoint(x: 106, y: 96), withAttributes: [.font: NSFont.systemFont(ofSize: 260)])
        img.unlockFocus(); return img
    }()

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func add(_ t: String, _ sel: Selector?, key: String = "", on: Bool = false, enabled: Bool = true) -> NSMenuItem {
            let m = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            m.target = self; m.state = on ? .on : .off; m.isEnabled = enabled && sel != nil; menu.addItem(m); return m
        }
        func header(_ t: String) { let m = NSMenuItem(title: t, action: nil, keyEquivalent: ""); m.isEnabled = false; menu.addItem(m) }

        switch b.stage {
        case .workReady: header("Ready. Press Go to start \(b.workMin) min of work")
        case .working: header("Working · \(fmt(b.endAt.timeIntervalSinceNow)) left")
        case .workPaused: header("Paused · \(fmt(b.remaining)) left")
        case .morning: header(b.awayUntil.map { "Morning list: back in \(fmt($0.timeIntervalSinceNow))" } ?? "Good morning. \(b.checksLeft) to go before work")
        case .dayOff, .evening: header("Done for today")
        default: header("On a break: \(b.act.map { "\($0.emoji) \($0.name)" } ?? "spinning")")
        }
        menu.addItem(.separator())
        switch b.stage {
        case .workReady: add("Go (Start Work)", #selector(startWork), key: "s")
        case .working: add("Pause", #selector(pauseWork), key: "s")
        case .workPaused: add("Resume", #selector(startWork), key: "s")
        case .morning: add("Show Morning Screen", #selector(showOverlay))
        default: add("Show Break Screen", #selector(showOverlay))
        }
        if b.stage != .morning { add("☀️ This Morning's Brief", #selector(showMorningAgain)) }
        if !b.houseStats.isEmpty { add("🏠 The House", #selector(showHouse)) }
        add("Take Break Now", #selector(breakNow), key: "b", enabled: [.workReady, .working, .workPaused].contains(b.stage))
        add("Reset", #selector(reset))
        menu.addItem(.separator())

        let (full, total) = Engine.fullDaysThisWeek(b.history, now: Date(), cap: b.cap, workdays: b.workdays)
        header("Capacity: \(b.blocksToday)/\(b.cap) blocks today · \(full)/\(total) full days this week")
        if let m = ding.nextMeeting(before: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)) {
            let t = DateFormatter(); t.timeStyle = .short
            header("📅 Next: \(m.title ?? "Meeting") at \(t.string(from: m.startDate))")
        } else if !ding.calOK { add("📅 Connect Calendar…", #selector(connectCal)) }
        if ding.calOK {
            let parent = NSMenuItem(title: "My Meeting Calendars", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let h = NSMenuItem(title: "Breaks end early only for checked calendars", action: nil, keyEquivalent: ""); h.isEnabled = false; sub.addItem(h)
            sub.addItem(.separator())
            for c in ding.allCalendars {
                let m = NSMenuItem(title: "\(c.title)  ·  \(c.source.title)", action: #selector(toggleCal(_:)), keyEquivalent: "")
                m.target = self; m.representedObject = c.calendarIdentifier; m.state = ding.isMeetingCalendar(c) ? .on : .off
                sub.addItem(m)
            }
            parent.submenu = sub; menu.addItem(parent)
        }
        header(b.workSummary)
        header("Today: \(b.didCount) breaks done · \(b.streak)🔥 · \(b.breakMinutes) min off-screen")
        let logItem = NSMenuItem(title: "Today's Log", action: nil, keyEquivalent: "")
        let sub = NSMenu(); let cat = b.catalog(); let t = DateFormatter(); t.timeStyle = .short
        if b.today.isEmpty { sub.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "") }
        for x in b.today.reversed() {
            let a = cat.activities.first { $0.id == x.id }
            let mark = x.skipped == true ? "✨" : (x.completed == true ? "✅" : (x.completed == false ? "❌" : "⏳"))
            sub.addItem(withTitle: "\(mark) \(t.string(from: x.at))  \(a.map { "\($0.emoji) \($0.name)" } ?? x.id)", action: nil, keyEquivalent: "")
            if let n = x.note, x.skipped != true {
                let m = NSMenuItem(title: "      " + n, action: nil, keyEquivalent: ""); m.isEnabled = false; sub.addItem(m)
            }
        }
        logItem.submenu = sub; menu.addItem(logItem)
        menu.addItem(.separator())

        menu.addItem(durationMenu("Work Length", current: b.workMin, options: [1, 3, 5, 10, 15, 25], sel: #selector(setWork(_:))))
        menu.addItem(durationMenu("Break Length", current: b.breakMin, options: [5, 10, 15, 20, 25, 30, 45, 60], sel: #selector(setBreak(_:))))
        let capItem = NSMenuItem(title: "Daily Capacity: \(b.cap) blocks", action: nil, keyEquivalent: "")
        let capSub = NSMenu()
        for v in [6, 8, 10, 12, 14, 16, 18] {
            let m = NSMenuItem(title: "\(v) blocks (≈ \(String(format: "%g", Double(v * (b.workMin + b.breakMin)) / 60)) h)", action: #selector(setCap(_:)), keyEquivalent: "")
            m.target = self; m.tag = v; m.state = v == b.cap ? .on : .off; capSub.addItem(m)
        }
        capItem.submenu = capSub; menu.addItem(capItem)
        add("Weekends Are Reset Days", #selector(toggleWeekends), on: b.weekendsOff)
        let endItem = NSMenuItem(title: "Workday Ends: \(b.workEnd > 12 ? b.workEnd - 12 : b.workEnd) PM", action: nil, keyEquivalent: "")
        let endSub = NSMenu()
        for h in [15, 16, 17, 18] {
            let m = NSMenuItem(title: "\(h - 12) PM", action: #selector(setWorkEnd(_:)), keyEquivalent: ""); m.target = self; m.tag = h
            m.state = h == b.workEnd ? .on : .off; endSub.addItem(m)
        }
        endItem.submenu = endSub; menu.addItem(endItem)
        add("Preview Tomorrow Morning", #selector(previewMorning))
        add("Focus Guard (work apps only)", #selector(toggleGuard), on: b.focusGuard)
        add("Edit Allowed Apps…", #selector(editAllow))
        if briefScript != nil {
            add(briefingRunning ? "Writing Today's Briefing…" : "Rewrite Today's Briefing", #selector(rewriteBriefing), enabled: !briefingRunning && !eveningRunning)
        }
        if b.hasEveningBrief {
            add(eveningRunning ? "Writing Evening Briefing…" : "Rewrite Evening Briefing", #selector(rewriteEvening), enabled: !eveningRunning && !briefingRunning)
        }
        if briefScript == nil {
            add("Copy Today's Brief Request", #selector(copyBriefRequest))
            add("Paste Today's Brief", #selector(pasteBrief))
        }
        add("Test Watch Ding (1 min)", #selector(testDing))
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings), key: ",")
        add("Edit Activities File…", #selector(editActs))
        if #available(macOS 13.0, *) { add("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled) }
        menu.addItem(.separator())
        add("Quit SpinBreak", #selector(quit), key: "q")
    }

    func durationMenu(_ title: String, current: Int, options: [Int], sel: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: "\(title): \(current) min", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in options {
            let m = NSMenuItem(title: "\(v) min", action: sel, keyEquivalent: ""); m.target = self; m.tag = v
            m.state = v == current ? .on : .off; sub.addItem(m)
        }
        parent.submenu = sub; return parent
    }

    @objc func showOverlay() { overlay.show() }
    @objc func setWork(_ m: NSMenuItem) { b.workMin = m.tag; if b.stage == .workReady { b.remaining = b.workLen }; render() }
    @objc func setBreak(_ m: NSMenuItem) { b.breakMin = m.tag }
    @objc func editActs() { _ = b.catalog(); NSWorkspace.shared.open(b.catalogURL) }
    @objc func resetActs() { try? FileManager.default.removeItem(at: b.catalogURL); _ = b.catalog(); settingsModel.reload() }

    // MARK: settings window
    lazy var settingsModel = SettingsModel(b: brain) { [weak self] in self?.render() }
    lazy var settingsWin: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "SpinBreak Settings"; w.isReleasedWhenClosed = false; w.center()
        w.contentView = NSHostingView(rootView: SettingsView(m: settingsModel, b: brain, app: self))
        return w
    }()
    @objc func showSettings() {
        settingsModel.reload()
        // Above the full-screen break overlay, if it's up.
        settingsWin.level = overlay.windows.isEmpty ? .normal : NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true); settingsWin.makeKeyAndOrderFront(nil)
    }
    func settingsChanged() { if b.stage == .workReady { b.remaining = b.workLen }; render() }
    func finishSetup() { b.setupDone = true; settingsWin.close(); showDash() }
    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            let s = SMAppService.mainApp; guard sandbox == nil else { return }
            do { if s.status == .enabled { try s.unregister() } else { try s.register() } } catch {}
        }
    }
    @objc func setWorkEnd(_ m: NSMenuItem) { b.workEnd = m.tag; render() }
    @objc func setCap(_ m: NSMenuItem) { b.cap = m.tag; render() }
    @objc func toggleWeekends() { b.weekendsOff.toggle(); render() }
    @objc func toggleGuard() { b.focusGuard.toggle() }
    @objc func editAllow() { _ = b.allowlist(); NSWorkspace.shared.open(b.allowURL) }
    @objc func toggleCal(_ m: NSMenuItem) {
        guard let id = m.representedObject as? String else { return }
        ding.setMeetingCalendar(id, m.state != .on)
    }
    @objc func connectCal() {
        ding.requestCalendar {
            if !self.ding.calOK { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }

@main
enum Main {
    static let delegate = AppDelegate()
    static func main() {
        // `SpinBreak --print-setup-prompt`: the prompt the Your AI tab copies, on stdout (for testing the install flow).
        if CommandLine.arguments.contains("--print-setup-prompt") { print(AISetup.setupPrompt(dir: Brain().dir, rooms: nil)); return }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)   // Dock icon + window: your menu bar auto-hides, so the tomato alone is easy to lose
        app.run()
    }
}
