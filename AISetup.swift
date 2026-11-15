// Setting SpinBreak up with your own AI (ChatGPT, Claude, Grok, anything):
// 1. The app gives you a prompt. Your AI interviews you (morning list, goals, people, rooms, workday, brief).
// 2. An AI that can run commands on this Mac saves setup.json in the SpinBreak folder, and the app answers in
//    setup-status.json. A chat-only AI replies with one JSON block that you paste back.
// 3. The brief: an AI on this Mac also writes brief.sh, a tiny script that runs it on brief-prompt.md. The app
//    fires that every morning (see "the daily brief" in SpinBreak.swift). With a chat-only AI you copy
//    "today's request" into it each morning and paste the answer back.
import AppKit
import Foundation
import ServiceManagement

enum AISetup {
    // MARK: the prompt

    static func setupPrompt(dir: URL, rooms: String?) -> String {
        let d = dir.path
        return """
        You're finishing the install of SpinBreak, a Mac app I just opened for the first time. Interview me, then set it up for me.

        WHAT SPINBREAK IS
        A reversed pomodoro. I work in short bursts (usually 5 minutes: long enough to steer my AI tools or finish one small thing), then take a long break (usually 25 minutes) doing something real in my life. A slot-machine spinner picks each break from my list of activities, under rules: time windows, daily aims per category, weekly limits. Cleaning is split into rooms; after I clean one I rate how messy it was, and rough rooms come back sooner. Every workday opens on a full-screen morning checklist I have to get through before work, next to a morning brief that you will write for me each day.

        FIRST, WORK OUT WHICH KIND OF AI YOU ARE
        A. You can run shell commands and write files on this Mac (Claude Code, Codex, Cursor, Gemini CLI, opencode, a desktop app with computer access). You do the whole install yourself: steps 1 to 4.
        B. You're a chat with no access to my Mac. Do steps 1 and 2, then read "IF YOU'RE A CHAT" at the end.
        SpinBreak's folder on this Mac is:
          \(d)
        If you're kind A, check that the folder exists before you start. If it doesn't, you're not on my Mac: you're kind B.

        STEP 1 · INTERVIEW ME
        Conversationally, two or three questions at a time, not a form. Offer examples when I'm stuck, and move on once you have enough. Cover:
        1. My name, and the town I live in (for sunrise, sunset and weather).
        2. My workday: when it starts and ends, whether weekends are off, how long work bursts and breaks should be (default 5 and 25).
        3. My morning list: what has to be true before I'm allowed to start work? 5 to 8 short items I can honestly check off (water, teeth, bed made, outside light, breakfast, a prayer, knowing the one thing that matters today…).
        4. What I want to fill my breaks with: my goals right now (health, fitness, relationships, learning, creative work, faith, money, a project), what I love doing, what I keep meaning to do and don't, what has to happen regularly (meals, walks, errands, pets), and anything that's off limits.
        5. Who I live with (partner, kids, pets, roommates) and what good time with them looks like.
        6. The rooms and spaces of my home that need regular cleaning (kitchen, each bathroom, bedrooms, kids' rooms, entry, office, garage, car, yard…), and roughly how often each needs it.
        7. My morning brief: what I'd like to read each morning (weather, today's calendar, follow-ups from yesterday, a nudge on a goal, a verse or quote, a word of the day, a phrase in a language I'm learning…), in what order, and in what tone.
        8. Whether SpinBreak should open by itself when I log in. Recommend yes: it runs the morning screen and the daily brief.
        \(rooms.map { "\nI share my home with someone who already uses SpinBreak. Use these room ids for the same rooms, so our two spinners split the cleaning instead of doubling up:\n\($0)\n" } ?? "\nIf I share my home with someone who already uses SpinBreak, ask me for their room list (their SpinBreak › Settings › Household › Copy my rooms) and reuse those exact ids for the same rooms.\n")
        STEP 2 · BUILD MY LIST
        Aim for 30 to 50 activities, spread across 7 to 10 categories that fit MY life. Every activity is a concrete 25-minute thing I could start right now, not a vague goal: "Walk to the park and back", not "Exercise". Include one activity per room (that's how cleaning gets spread out), plus meals, movement, time outside, people, and my goals. Show me a short summary (each category with a few examples, my morning list, the sections of my brief) and ask what's missing or wrong before you write anything.

        THE JSON
        One JSON object in this shape (the comments are explanations, don't include them):
        {
          "spinbreak": 1,
          "name": "Sam",
          "place": "Boise, Idaho",                          // city and state or country; the app looks it up
          "settings": {
            "workMinutes": 5, "breakMinutes": 25,           // work burst and break length
            "workdayEnds": 17,                              // hour, 24h clock; the screen locks for the evening after this
            "weekendsOff": true,                            // weekends are reset days with no work
            "dailyBlocks": 14,                              // most work+break blocks in a day
            "eveningLock": true,
            "openAtLogin": true                             // what I answered to question 8
          },
          "brief": "Instructions for writing my morning brief, in your words, from what I told you: the sections and their order, the tone, what to leave out, what I'm working toward. Name anything that changes daily (a word of the day, a phrase, a quote). 100 to 250 words.",
          "checklist": ["💧 Big glass of water", "🛏️ Bed made", "…"],
          "categories": {                                   // per category: target = aim per day, cap = most per day
            "outdoors": {"target": 2, "cap": 4},
            "home": {"target": 2, "cap": 4}
          },
          "groups": {                                       // optional shared limits across activities in a group
            "clean": {"cap": 2, "gap": 120}                 // at most 2 rooms a day, 120+ minutes apart
          },
          "activities": [
            {
              "id": "clean-kitchen",                        // lowercase-with-dashes, unique; rooms MUST start with "clean-"
              "emoji": "🍽️",
              "name": "Kitchen reset",                      // short, shown huge on screen
              "category": "home",                           // must be a key in "categories"
              "how": "Dishes, counters, sink, floor. Leave it ready for the next meal.",   // one or two sentences of exactly what to do
              "groups": ["clean"],                          // every room is in the "clean" group; that's what makes it a room
              "weeklyMax": 2,                               // optional: at most this many times a week
              "weight": 3                                   // optional, 1-5: how often it should come up (default 3)
            }
          ]
        }
        Optional fields for any activity (leave them out unless they matter):
          "from": 9, "to": 17                 earliest and latest hour it may START (24h, decimals ok: 12.5 = 12:30). Default 8 to 22.
          "maxPerDay": 2, "minGap": 120       repeats per day (default 1) and minutes between repeats
          "days": [2,3,4,5,6]                 only these weekdays (1 = Sunday … 7 = Saturday)
          "daylight": true                    only while it's light out (outdoor things)
          "anchor": "12:00-13:00"             force it whenever a break lands in that window (meals). "sun" = within 2.5 h of sunrise
          "soft": "12:30-14:00"               much more likely in that window
          "next": "some-other-id"             always comes right after this one (cook dinner → eat dinner)
          "seated": true                      a sitting activity; never two in a row
          "notFirst": true                    never the first break of the day
          "months": [5,6,7,8,9]               only in these months
        Good rules of thumb: rooms get "groups": ["clean"] and a weeklyMax of 1 to 3; hard exercise gets a group with "cap": 1; meals get anchors; anything outside gets "daylight": true; category targets should add up to about 10 to 14 a day.

        STEP 3 · SAVE IT (kind A)
        Save the JSON as \(d)/setup.json. Write it under another name first (setup.json.tmp) and rename it, so SpinBreak never reads half a file. SpinBreak has to be open. It imports the file within a few seconds and answers in \(d)/setup-status.json: {"ok": true, "summary": "…"} or {"ok": false, "error": "…"}. Read that file. If ok is false, fix the JSON and save it again. Don't edit activities.json or anything else in the folder yourself; the app owns those files.

        STEP 4 · THE DAILY BRIEF JOB (kind A)
        SpinBreak is the scheduler, so do NOT create a launchd job, a cron entry, a reminder or a cloud routine (a cloud job can't reach this folder anyway). Every morning, as soon as my Mac is awake after 5 am, SpinBreak:
        - refreshes context.json: today's date, sunrise and sunset, my calendar for today and tomorrow, yesterday's break log with my notes, how my rooms are doing, and "alreadyUsed" (the words, phrases and quotes my recent briefs already featured, so nothing repeats);
        - rewrites brief-prompt.md: the complete instructions for today's brief, with brief-style.md (the "brief" text from my JSON) and today's data already inside it;
        - runs brief.sh from the folder, saves the brief it prints, tries again later if there isn't one, and shows me when it fails.
        Your part is that one small file. Its whole job: run you, non-interactively, on brief-prompt.md, and print the brief on standard output.
        1. Find the full path of your own command-line tool (for example: command -v claude).
        2. Write \(d)/brief.sh. Give the writer the web (searching, and reading the pages it finds) and NOTHING else: no reading or writing files, no shell, no other connectors. That is on purpose. The brief is written from calendar titles and web pages that other people wrote, and a writer that can't touch my Mac can't be talked into harming it. It doesn't need more: everything is inside brief-prompt.md, SpinBreak saves what it prints, and the web is how it works out the weather and anything else I asked for. For Claude Code it is exactly these two lines:
             #!/bin/sh
             exec /full/path/to/claude -p "$(cat brief-prompt.md)" --tools "WebSearch,WebFetch" --allowedTools "WebSearch" "WebFetch" --strict-mcp-config
           For Codex, use "codex exec --skip-git-repo-check" with a read-only sandbox and web access turned on. For anything else, read your own --help for the non-interactive mode and for how to switch every tool off except the web. Use full paths, because the job doesn't get my shell's PATH. Then: chmod +x brief.sh
        3. Prove it through SpinBreak, not from your terminal. The app's environment is the one that has to work:
             touch "\(d)/brief.run-now"
           SpinBreak starts the job within 5 seconds. Read brief-status.json every 15 seconds or so until "state" is "ok" or "failed" (a run usually takes one to three minutes). If it failed, read "detail" there, brief.out (what your script printed) and brief.log (its errors), fix brief.sh, and touch brief.run-now again. Don't stop at "it should work".
        4. Read the brief (its path is in brief-status.json), show it to me, and ask what I'd change. How it's written lives in brief-style.md, plain text, re-read on every run: edit that and run the job again.

        WHEN YOU'RE DONE
        Tell me in a few lines what you set up and how I change it later (SpinBreak › Settings for the list and the morning checklist; brief-style.md or Settings › Your AI for the brief). Then tell me to go back to SpinBreak and press "I'm set, let's go".

        IF YOU'RE A CHAT (kind B)
        Reply with the JSON as exactly one ```json code block. Tell me to copy your whole answer, then in SpinBreak › Settings › Your AI press "Read it from the clipboard" and "Use this setup". After that my brief works by copy and paste: each morning SpinBreak has a "Copy today's request" button; I paste the request to you and paste your answer back. Say that plainly so I know what to expect, and if you can schedule a daily reminder for me, offer to.
        """
    }

    /// What gets pasted into the AI each morning (when it isn't writing the brief on its own).
    static func briefRequest(brief: String?, context: String, name: String) -> String {
        let style = brief?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Brief.fallbackStyle
        return """
        Write my SpinBreak morning brief for today\(name.isEmpty ? "" : ", \(name)"). I'll read it on a full-screen page while I do my morning checklist. It's about my life, not my job.

        How I want it:
        \(style)

        \(Brief.format) Reply with just the brief, so I can paste it straight in. Look up today's weather where I live if you can.

        \(Brief.noRepeats)

        Today's data from SpinBreak (calendar, sunrise and sunset, yesterday's log and notes, rooms, computer time, alreadyUsed):
        ```json
        \(context)
        ```
        """
    }

    // MARK: importing what the AI wrote

    struct Imported {
        var catalog: Catalog
        var name: String?
        var place: String?
        var brief: String?
        var settings: [String: Any]
        var summary: String
    }
    struct ImportError: Error, LocalizedError { let msg: String; var errorDescription: String? { msg } }

    /// Finds the JSON in whatever got pasted (a fenced block, prose around it, smart quotes) and turns it
    /// into a catalog. Forgiving on purpose: missing fields get defaults, unknown categories get created,
    /// broken links are dropped. Throws only when there's nothing usable.
    static func parse(_ raw: String) throws -> Imported {
        var s = raw
        if let r = s.range(of: "```json") ?? s.range(of: "```") {
            s = String(s[r.upperBound...]); if let e = s.range(of: "```") { s = String(s[..<e.lowerBound]) }
        }
        guard let a = s.firstIndex(of: "{"), let z = s.lastIndex(of: "}") else {
            throw ImportError(msg: "There's no JSON in what you pasted. Copy the whole ```json block your AI wrote.")
        }
        s = String(s[a...z])
        var parsed = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
        // Not valid as-is: AIs sometimes leave // comments, trailing commas or curly quotes in. Clean those and retry.
        if parsed == nil { s = s.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"") }
        s = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var inStr = false, prev: Character = " ", out = ""
            for ch in line {
                if ch == "\"" && prev != "\\" { inStr.toggle() }
                if !inStr && ch == "/" && prev == "/" { out.removeLast(); break }
                out.append(ch); prev = ch
            }
            return out
        }.joined(separator: "\n")
        s = s.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        if parsed == nil { parsed = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] }
        guard let obj = parsed else {
            throw ImportError(msg: "That JSON doesn't parse. Ask your AI: \"Please resend the SpinBreak JSON as one valid ```json block.\"")
        }
        let root = (obj["catalog"] as? [String: Any]) ?? obj
        guard let rawActs = root["activities"] as? [[String: Any]], !rawActs.isEmpty else {
            throw ImportError(msg: "The JSON has no activities in it. Ask your AI to include the \"activities\" list.")
        }

        // Each activity on top of a default one, so leaving fields out is fine.
        let base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(
            Activity(id: "", emoji: "⭐️", name: "", category: "", how: "")))) as? [String: Any] ?? [:]
        var acts: [Activity] = [], seen = Set<String>(), skipped = 0
        for r in rawActs {
            var m = base
            for (k, v) in r where !(v is NSNull) { m[k] = v }
            if let n = m["from"] as? String { m["from"] = Double(n) }; if let n = m["to"] as? String { m["to"] = Double(n) }
            guard let data = try? JSONSerialization.data(withJSONObject: m), var act = try? JSONDecoder().decode(Activity.self, from: data),
                  !act.name.trimmingCharacters(in: .whitespaces).isEmpty else { skipped += 1; continue }
            act.id = slug(act.id.isEmpty ? act.name : act.id)
            while seen.contains(act.id) { act.id += "-2" }
            act.category = slug(act.category.isEmpty ? "other" : act.category)
            if act.emoji.isEmpty { act.emoji = "⭐️" }
            act.next = act.next.map(slug)
            if act.from >= act.to { act.from = 8; act.to = 22 }
            act.weight = max(0.5, min(10, act.weight)); act.maxPerDay = max(1, act.maxPerDay)
            if act.id.hasPrefix("clean-") && !(act.groups ?? []).contains("clean") { act.groups = (act.groups ?? []) + ["clean"] }
            seen.insert(act.id); acts.append(act)
        }
        for i in acts.indices where acts[i].next.map({ !seen.contains($0) }) ?? false { acts[i].next = nil }
        guard !acts.isEmpty else { throw ImportError(msg: "None of the activities could be read. Ask your AI to resend the JSON.") }

        var cats: [String: CategoryRule] = [:]
        for (k, v) in root["categories"] as? [String: Any] ?? [:] {
            let d = v as? [String: Any] ?? [:]
            let t = (d["target"] as? NSNumber)?.intValue ?? 1, c = (d["cap"] as? NSNumber)?.intValue ?? max(3, t)
            cats[slug(k)] = CategoryRule(target: max(0, t), cap: max(t, c))
        }
        for a in acts where cats[a.category] == nil { cats[a.category] = CategoryRule(target: 1, cap: 3) }
        var groups: [String: GroupRule] = [:]
        for (k, v) in root["groups"] as? [String: Any] ?? [:] {
            let d = v as? [String: Any] ?? [:]
            groups[k] = GroupRule(cap: max(1, (d["cap"] as? NSNumber)?.intValue ?? 2), gap: (d["gap"] as? NSNumber)?.intValue)
        }
        if acts.contains(where: Engine.isRoom), groups["clean"] == nil { groups["clean"] = GroupRule(cap: 2, gap: 120) }

        let here = Engine.guessedLocation()
        var cat = Catalog(latitude: here.lat, longitude: here.lon, horizon: nil, groups: groups, categories: cats, activities: acts)
        if let list = root["checklist"] as? [String] { cat.checklist = list.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        // Round-trip so we know the app will read exactly this file back.
        guard let check = try? JSONEncoder().encode(cat), (try? JSONDecoder().decode(Catalog.self, from: check)) != nil else {
            throw ImportError(msg: "Something in that list didn't fit SpinBreak's format. Ask your AI to resend the JSON.")
        }
        let rooms = acts.filter(Engine.isRoom).count
        var summary = "\(acts.count) activities in \(cats.count) categories, \(rooms) room\(rooms == 1 ? "" : "s")"
        if let c = cat.checklist { summary += ", a \(c.count)-item morning checklist" }
        if obj["brief"] is String { summary += ", your brief instructions" }
        if skipped > 0 { summary += " (\(skipped) unreadable item\(skipped == 1 ? "" : "s") left out)" }
        return Imported(catalog: cat, name: obj["name"] as? String, place: obj["place"] as? String, brief: obj["brief"] as? String,
                        settings: obj["settings"] as? [String: Any] ?? [:], summary: summary)
    }

    static func slug(_ s: String) -> String {
        let t = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(t).split(separator: "-").joined(separator: "-").nilIfEmpty ?? "item-\(UUID().uuidString.prefix(4).lowercased())"
    }

    /// Writes it all: backs up the old list first, then the catalog, settings, brief instructions and place.
    static func apply(_ x: Imported, to b: Brain) {
        let fm = FileManager.default
        if fm.fileExists(atPath: b.catalogURL.path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            try? fm.copyItem(at: b.catalogURL, to: b.dir.appendingPathComponent("activities.before-\(f.string(from: Date())).json"))
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(x.catalog).write(to: b.catalogURL, options: .atomic)
        let s = x.settings
        func int(_ k: String) -> Int? { (s[k] as? NSNumber)?.intValue }
        func bool(_ k: String) -> Bool? { (s[k] as? NSNumber)?.boolValue }
        if let v = int("workMinutes"), (1...60).contains(v) { b.workMin = v }
        if let v = int("breakMinutes"), (5...90).contains(v) { b.breakMin = v }
        if let v = int("workdayEnds"), (12...23).contains(v) { b.workEnd = v }
        if let v = int("dailyBlocks"), (2...24).contains(v) { b.cap = v }
        if let v = bool("weekendsOff") { b.weekendsOff = v }
        if let v = bool("eveningLock") { b.eveningLock = v }
        if bool("openAtLogin") == true, sandbox == nil, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        if let n = x.name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { Household.name = n; b.d.set(n, forKey: "personName") }
        if let br = x.brief { b.briefStyle = br }
        b.d.set(x.summary, forKey: "setupImported")
        b.objectWillChange.send()
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
