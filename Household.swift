// Household cleaning: two SpinBreaks in one home share an iCloud calendar called "SpinBreak Home".
// When the spin lands on a room, it goes on that calendar right away ("claimed"); when the break ends it's
// marked done with its mess rating. Each Mac reads the other's entries so you split the rooms instead of
// both doing the kitchen, rough rooms come back for whoever spins next, and while one of you is cleaning
// the other's spinner leans toward a different room so you clean at the same time.
//
// No server: the calendar is shared once by hand in Calendar.app (EventKit can't share calendars).
// If no calendar by that name exists, all of this is invisible.
import AppKit
import EventKit

extension Ding {
    static let homeTitle = "SpinBreak Home"

    var homeCalendar: EKCalendar? {
        guard calOK else { return nil }
        let cals = ek.calendars(for: .event).filter { $0.title == Ding.homeTitle && $0.allowsContentModifications }
        guard cals.count > 1 else { return cals.first }
        // Two by the same name (someone pressed Create before accepting the share): use the one where
        // someone else's rooms show up; that's the shared one.
        let now = Date()
        return cals.first { c in
            ek.events(matching: ek.predicateForEvents(withStart: now.addingTimeInterval(-30 * 86400), end: now.addingTimeInterval(86400), calendars: [c]))
                .contains { Ding.roomInfo($0).map { $0["by"] != Household.me } ?? false }
        } ?? cals.first
    }

    /// Makes the calendar on iCloud so it can be shared. Returns nil if there's no iCloud calendar account.
    func makeHomeCalendar() -> EKCalendar? {
        if let c = homeCalendar { return c }
        guard calOK, let src = eventCalendar()?.source else { return nil }
        let c = EKCalendar(for: .event, eventStore: ek); c.title = Ding.homeTitle; c.source = src
        c.cgColor = NSColor(red: 0.95, green: 0.62, blue: 0.25, alpha: 1).cgColor
        do { try ek.saveCalendar(c, commit: true); return c } catch { return nil }
    }

    /// What's on the house calendar, as a link: spinbreak://room?id=clean-kitchen&name=Kitchen&by=<install>&who=Sam&state=claimed&mess=3
    static func roomURL(_ a: Activity, state: String, mess: Int? = nil) -> URL? {
        var c = URLComponents(); c.scheme = "spinbreak"; c.host = "room"
        c.queryItems = [URLQueryItem(name: "id", value: a.id), URLQueryItem(name: "name", value: a.name),
                        URLQueryItem(name: "by", value: Household.me), URLQueryItem(name: "who", value: Household.name),
                        URLQueryItem(name: "state", value: state)] + (mess.map { [URLQueryItem(name: "mess", value: String($0))] } ?? [])
        return c.url
    }

    /// The room data on an event: from its URL, or from the last line of its notes (in case a calendar server drops URLs).
    static func roomInfo(_ e: EKEvent) -> [String: String]? {
        let u = e.url.flatMap { $0.scheme == "spinbreak" ? $0 : nil }
            ?? e.notes?.components(separatedBy: "\n").last(where: { $0.hasPrefix("spinbreak://") }).flatMap(URL.init(string:))
        guard let u, u.host == "room", let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return Dictionary(q.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// The spin landed on a room: put it on the house calendar now so the other spinner skips it.
    func claimRoom(_ a: Activity, until end: Date, state: String = "claimed", mess: Int? = nil) -> String? {
        guard Engine.isRoom(a), let cal = homeCalendar else { return nil }
        let e = EKEvent(eventStore: ek); e.calendar = cal
        e.title = state == "spotless" ? "✨ \(a.name) · \(Household.name) found it spotless" : "\(a.emoji) \(a.name) · \(Household.name)"
        e.startDate = Date(); e.endDate = max(Date().addingTimeInterval(60), end); e.availability = .free
        e.url = Ding.roomURL(a, state: state, mess: mess); e.notes = a.how + "\n\n" + (e.url?.absoluteString ?? "")
        do { try ek.save(e, span: .thisEvent, commit: true); return e.eventIdentifier } catch { return nil }
    }

    /// A room finished somewhere else (the watch): put it on the house calendar after the fact, once.
    func logRoom(_ a: Activity, _ x: Done) {
        guard Engine.isRoom(a), x.completed == true, let cal = homeCalendar else { return }
        let key = "house-\(a.id)-\(Int(x.at.timeIntervalSince1970))"
        guard !prefs.bool(forKey: key) else { return }
        // Already there (the Mac claimed it when the break started)?
        let near = ek.events(matching: ek.predicateForEvents(withStart: x.at.addingTimeInterval(-600), end: x.at.addingTimeInterval(600), calendars: [cal]))
        if near.contains(where: { e in Ding.roomInfo(e).map { $0["by"] == Household.me && $0["id"] == a.id } ?? false }) {
            prefs.set(true, forKey: key); return
        }
        let e = EKEvent(eventStore: ek); e.calendar = cal; e.availability = .free
        e.title = "\(a.emoji) \(a.name) · \(Household.name)" + (x.mess.map { " · " + ["", "✨ fine", "😐 meh", "🔥 rough"][$0] } ?? "")
        e.startDate = x.at; e.endDate = x.at.addingTimeInterval(max(60, (x.mins ?? 25) * 60))
        e.url = Ding.roomURL(a, state: "done", mess: x.mess); e.notes = a.how + "\n\n" + (e.url?.absoluteString ?? "")
        if (try? ek.save(e, span: .thisEvent, commit: true)) != nil { prefs.set(true, forKey: key) }
    }

    /// Break over: done or not, with how bad it was.
    func settleRoom(_ id: String?, _ a: Activity, didIt: Bool, mess: Int?) {
        guard let id, let e = ek.event(withIdentifier: id) else { return }
        e.url = Ding.roomURL(a, state: didIt ? "done" : "skipped", mess: mess); e.notes = a.how + "\n\n" + (e.url?.absoluteString ?? "")
        if !didIt { e.title = "↩︎ \(a.name) · \(Household.name) didn't get to it" }
        else if let mess { e.title = "\(a.emoji) \(a.name) · \(Household.name) · \(["", "✨ fine", "😐 meh", "🔥 rough"][mess])" }
        if e.endDate.timeIntervalSinceNow > 0 { e.endDate = max(e.startDate.addingTimeInterval(60), Date()) }
        try? ek.save(e, span: .thisEvent, commit: true)
    }

    /// Everyone else's rooms from the last 8 days, mapped onto this catalog's rooms.
    func household(_ c: Catalog) -> (entries: [Done], live: [(who: String, room: String)]) {
        guard let cal = homeCalendar else { return ([], []) }
        let now = Date()
        let evs = ek.events(matching: ek.predicateForEvents(withStart: now.addingTimeInterval(-8 * 86400), end: now.addingTimeInterval(3 * 3600), calendars: [cal]))
        let rooms = c.activities.filter(Engine.isRoom)
        var out: [Done] = [], live: [(String, String)] = []
        for e in evs {
            guard let info = Ding.roomInfo(e) else { continue }
            func v(_ k: String) -> String? { info[k] }
            guard v("by") != Household.me, let theirID = v("id") else { continue }
            let state = v("state") ?? "claimed"
            if state == "skipped" { continue }
            guard let mine = Household.match(theirID, v("name") ?? "", in: rooms) else { continue }
            let onIt = state == "claimed" && e.startDate <= now && e.endDate.addingTimeInterval(10 * 60) > now
            if onIt { live.append((v("who") ?? "Someone", v("name") ?? mine.name)) }
            out.append(Done(id: mine.id, category: mine.category, at: e.startDate,
                            completed: state == "done" || state == "spotless" ? true : nil,
                            note: onIt ? "live" : "household", mins: state == "done" ? e.endDate.timeIntervalSince(e.startDate) / 60 : nil,
                            mess: state == "spotless" ? 1 : v("mess").flatMap(Int.init)))
        }
        return (out, live)
    }
}

enum Household {
    /// This install, so your own entries don't come back to you as someone else's.
    static var me: String {
        let d = prefs
        if let s = d.string(forKey: "houseMe") { return s }
        let s = UUID().uuidString; d.set(s, forKey: "houseMe"); return s
    }
    /// The name the other person sees on the calendar.
    static var name: String {
        get { prefs.string(forKey: "houseName").flatMap { $0.isEmpty ? nil : $0 }
              ?? NSFullUserName().components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 } ?? "Me" }
        set { prefs.set(newValue, forKey: "houseName") }
    }

    /// Their room → your room: same id, else same id without "clean-", else the room word shows up in the name.
    static func match(_ id: String, _ name: String, in rooms: [Activity]) -> Activity? {
        if let a = rooms.first(where: { $0.id == id }) { return a }
        func key(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "clean-", with: "") }
        if let a = rooms.first(where: { key($0.id) == key(id) }) { return a }
        let words = Set((key(id) + " " + name.lowercased()).split { !$0.isLetter }.map(String.init))
            .subtracting(["the", "clean", "deep", "room", "a", "and", "out", "your", "my", "reset", "tidy"])
        // Most words in common wins; a word that IS their id ("bath") counts double.
        let scored = rooms.map { r -> (Activity, Int) in
            let mine = Set((key(r.id) + " " + r.name.lowercased()).split { !$0.isLetter }.map(String.init))
            return (r, mine.intersection(words).count + (mine.contains(key(id)) ? 1 : 0))
        }
        return scored.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// For your partner's AI during their setup: your rooms, with the ids their spinner should reuse.
    static func roomList(_ c: Catalog) -> String {
        let rooms = c.activities.filter(Engine.isRoom)
        return "Our household's SpinBreak rooms (reuse these exact ids for the same rooms, so our spinners can split the cleaning):\n"
            + rooms.map { "- \($0.id): \($0.emoji) \($0.name)" }.joined(separator: "\n")
    }
}
