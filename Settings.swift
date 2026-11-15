// SpinBreak Settings: activities, balance, schedule and the morning checklist, without hand-editing JSON.
// Every change saves straight to activities.json (the same file "Edit Activities File…" opens).
import AppKit
import CoreLocation
import ServiceManagement
import SwiftUI

final class SettingsModel: ObservableObject {
    let b: Brain
    let changed: () -> Void
    @Published var cat: Catalog { didSet { save() } }
    @Published var sel: String?
    @Published var place: String
    @Published var tab = 0
    @Published var importMsg = ""
    @Published var pending: AISetup.Imported?

    init(b: Brain, changed: @escaping () -> Void) {
        self.b = b; self.changed = changed
        cat = b.catalog()
        place = b.d.string(forKey: "placeName") ?? ""
        tab = b.setupDone ? 0 : 4
    }

    func reload() { cat = b.catalog() }

    /// Reads the AI's answer off the clipboard and shows what it would set up (nothing is written yet).
    func previewPaste() {
        guard let t = NSPasteboard.general.string(forType: .string), !t.isEmpty else { pending = nil; importMsg = "The clipboard is empty. Copy your AI's whole answer first."; return }
        do { pending = try AISetup.parse(t); importMsg = "" } catch { pending = nil; importMsg = "⚠️ " + error.localizedDescription }
    }
    func confirmImport() {
        guard let x = pending else { return }
        AISetup.apply(x, to: b); pending = nil; reload()
        importMsg = "✅ Set up: \(x.summary). Your old list was backed up in the SpinBreak folder."
        if let p = x.place, !p.isEmpty { place = p; findPlace { err in if let err { self.importMsg += " " + err } } }
        changed()
    }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(cat).write(to: b.catalogURL, options: .atomic)
        changed()
    }

    func binding(_ id: String) -> Binding<Activity>? {
        guard cat.activities.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.cat.activities.first { $0.id == id } ?? Engine.freeChoice },
                       set: { v in if let i = self.cat.activities.firstIndex(where: { $0.id == id }) { self.cat.activities[i] = v } })
    }

    var categoryNames: [String] { cat.categories.keys.sorted() }

    func add() {
        let id = "my-\(UUID().uuidString.prefix(6).lowercased())"
        let category = categoryNames.contains("rest") ? "rest" : (categoryNames.first ?? "rest")
        if cat.categories[category] == nil { cat.categories[category] = CategoryRule(target: 1, cap: 3) }
        cat.activities.append(Activity(id: id, emoji: "⭐️", name: "New activity", category: category,
                                       how: "What exactly to do, in a sentence you'd want to read mid-break.", weight: 3))
        sel = id
    }
    func delete(_ id: String) {
        cat.activities.removeAll { $0.id == id }
        // Nothing may chain into a deleted item.
        for i in cat.activities.indices where cat.activities[i].next == id { cat.activities[i].next = nil }
        sel = nil
    }

    /// Looks the town up with Apple's geocoder (no location permission needed) for sunrise and sunset.
    func findPlace(_ done: @escaping (String?) -> Void) {
        CLGeocoder().geocodeAddressString(place) { marks, _ in
            DispatchQueue.main.async {
                guard let m = marks?.first, let loc = m.location else { return done("Couldn't find that place. Try “City, State” or “City, Country”.") }
                self.cat.latitude = (loc.coordinate.latitude * 1e4).rounded() / 1e4
                self.cat.longitude = (loc.coordinate.longitude * 1e4).rounded() / 1e4
                self.cat.horizon = nil
                let name = [m.locality, m.administrativeArea ?? m.country].compactMap { $0 }.joined(separator: ", ")
                self.place = name.isEmpty ? self.place : name
                self.b.d.set(self.place, forKey: "placeName")
                done(nil)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var b: Brain
    let app: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $m.tab) {
                ActivitiesTab(m: m).tabItem { Text("Activities") }.tag(0)
                BalanceTab(m: m).tabItem { Text("Balance") }.tag(1)
                ScheduleTab(m: m, b: b, app: app).tabItem { Text("Schedule") }.tag(2)
                MorningTab(m: m).tabItem { Text("Morning") }.tag(3)
                AITab(m: m, b: b, app: app).tabItem { Text("Your AI") }.tag(4)
                HouseholdTab(m: m, app: app).tabItem { Text("Household") }.tag(5)
            }
            .padding(12)
        }
        .frame(minWidth: 820, minHeight: 600)
    }
}

// MARK: Activities

struct ActivitiesTab: View {
    @ObservedObject var m: SettingsModel
    @State private var confirmReset = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $m.sel) {
                    ForEach(m.categoryNames + orphanCategories, id: \.self) { c in
                        let items = m.cat.activities.filter { $0.category == c }
                        if !items.isEmpty {
                            Section(pretty(c)) {
                                ForEach(items) { a in
                                    HStack(spacing: 8) {
                                        Toggle("", isOn: Binding(get: { a.off != true }, set: { on in m.binding(a.id)?.wrappedValue.off = on ? nil : true }))
                                            .labelsHidden().toggleStyle(.checkbox)
                                        Text(a.title).lineLimit(1).foregroundStyle(a.off == true ? .secondary : .primary)
                                    }
                                    .tag(a.id)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button { m.add() } label: { Image(systemName: "plus") }.help("Add an activity")
                    Button { if let s = m.sel { m.delete(s) } } label: { Image(systemName: "minus") }.disabled(m.sel == nil).help("Delete the selected activity")
                    Spacer()
                    let on = m.cat.activities.filter { $0.off != true }.count
                    Text("\(on) of \(m.cat.activities.count) on").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .frame(width: 300)
            Divider()
            Group {
                if let s = m.sel, let a = m.binding(s) { ActivityEditor(a: a, m: m) }
                else {
                    VStack(spacing: 12) {
                        Text("Pick an activity to edit it.").foregroundStyle(.secondary)
                        Text("Checked items can come up on the wheel. Uncheck anything that doesn't fit your life; it stays here if you want it back.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                        Spacer().frame(height: 20)
                        if confirmReset {
                            Text("Replace your whole list with the starter set?").font(.callout)
                            HStack {
                                Button("Cancel") { confirmReset = false }
                                Button("Replace it", role: .destructive) { m.cat.activities = Engine.freshCatalog().activities; confirmReset = false }
                            }
                        } else {
                            Button("Restore the starter list…") { confirmReset = true }
                        }
                        Button("Open the activities file (advanced)…") { NSWorkspace.shared.open(m.b.catalogURL) }
                            .buttonStyle(.link).font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    var orphanCategories: [String] { Array(Set(m.cat.activities.map(\.category)).subtracting(m.categoryNames)).sorted() }
}

func pretty(_ c: String) -> String { c.replacingOccurrences(of: "-", with: " ").capitalized }

func hourLabel(_ h: Double) -> String {
    if h <= 0 { return "Midnight" }
    if h >= 24 { return "Midnight (end)" }
    let hh = Int(h), mm = Int((h - Double(hh)) * 60)
    let h12 = hh % 12 == 0 ? 12 : hh % 12
    return "\(h12):\(String(format: "%02d", mm)) \(hh < 12 ? "AM" : "PM")"
}

struct ActivityEditor: View {
    @Binding var a: Activity
    @ObservedObject var m: SettingsModel
    static let halfHours = stride(from: 0.0, through: 24.0, by: 0.5).map { $0 }
    static let dayNames = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("", text: $a.emoji).frame(width: 44).multilineTextAlignment(.center)
                    TextField("Name", text: $a.name)
                }
                Picker("Category", selection: $a.category) {
                    ForEach(Array(Set(m.categoryNames + [a.category])).sorted(), id: \.self) { Text(pretty($0)).tag($0) }
                }
                TextField("What to do", text: $a.how, axis: .vertical).lineLimit(2...5)
            }
            Section("When") {
                Picker("Earliest start", selection: $a.from) { ForEach(Self.halfHours.dropLast(), id: \.self) { Text(hourLabel($0)).tag($0) } }
                Picker("Latest start", selection: $a.to) { ForEach(Self.halfHours.dropFirst(), id: \.self) { Text(hourLabel($0)).tag($0) } }
                HStack {
                    Text("Days")
                    Spacer()
                    ForEach(1...7, id: \.self) { d in
                        let on = a.days?.contains(d) ?? true
                        Button(Self.dayNames[d - 1]) {
                            var set = Set(a.days ?? Array(1...7))
                            if on { set.remove(d) } else { set.insert(d) }
                            a.days = set.count == 7 || set.isEmpty ? nil : set.sorted()
                        }
                        .buttonStyle(.bordered).tint(on ? accent : .gray).controlSize(.small)
                    }
                }
                Toggle("Only while it's light out", isOn: Binding(get: { a.daylight == true }, set: { a.daylight = $0 ? true : nil }))
            }
            Section("How often") {
                HStack {
                    Text("Comes up")
                    Slider(value: $a.weight, in: 0.5...8, step: 0.5)
                    Text(a.weight < 2 ? "Rarely" : a.weight < 4 ? "Sometimes" : a.weight < 6 ? "Often" : "A lot").frame(width: 72, alignment: .trailing)
                }
                Stepper("Up to \(a.maxPerDay) a day", value: $a.maxPerDay, in: 1...6)
                Toggle("Limit it per week", isOn: Binding(get: { a.weeklyMax != nil }, set: { a.weeklyMax = $0 ? 2 : nil }))
                if let w = a.weeklyMax {
                    Stepper("At most \(w) a week", value: Binding(get: { w }, set: { a.weeklyMax = $0 }), in: 1...14)
                }
            }
            Section {
                Toggle("Switched on", isOn: Binding(get: { a.off != true }, set: { a.off = $0 ? nil : true }))
                if a.anchor != nil || a.next != nil || !(a.groups ?? []).isEmpty || a.soft != nil {
                    Text("Also has advanced rules (\([a.anchor.map { "fixed time \($0)" }, a.soft.map { "preferred \($0)" }, a.next.map { "followed by \($0)" }, (a.groups ?? []).isEmpty ? nil : "groups \((a.groups ?? []).joined(separator: ", "))"].compactMap { $0 }.joined(separator: "; "))). Edit those in the activities file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Balance

struct BalanceTab: View {
    @ObservedObject var m: SettingsModel
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                Text("Each break comes from a category. SpinBreak tries to hit each one's daily aim and never goes over its limit.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Categories") {
                ForEach(m.categoryNames, id: \.self) { c in
                    let rule = m.cat.categories[c]!
                    let count = m.cat.activities.filter { $0.category == c && $0.off != true }.count
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pretty(c))
                            Text("\(count) activit\(count == 1 ? "y" : "ies") on").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper("Aim for \(rule.target)/day", value: Binding(get: { rule.target }, set: { v in
                            m.cat.categories[c] = CategoryRule(target: v, cap: max(v, rule.cap)) }), in: 0...8).frame(width: 170)
                        Stepper("Limit \(rule.cap)", value: Binding(get: { rule.cap }, set: { v in
                            m.cat.categories[c] = CategoryRule(target: min(v, rule.target), cap: v) }), in: 0...10).frame(width: 120)
                        if m.cat.activities.allSatisfy({ $0.category != c }) {
                            Button { m.cat.categories[c] = nil } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove this empty category")
                        }
                    }
                }
            }
            Section("New category") {
                HStack {
                    TextField("e.g. garden, faith, side project", text: $newName)
                    Button("Add") {
                        let k = newName.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
                        if !k.isEmpty, m.cat.categories[k] == nil { m.cat.categories[k] = CategoryRule(target: 1, cap: 3) }
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Schedule

struct ScheduleTab: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var b: Brain
    let app: AppDelegate
    @State private var placeMsg: String?
    @State private var finding = false
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Rhythm") {
                Picker("Work block", selection: Binding(get: { b.workMin }, set: { b.workMin = $0; app.settingsChanged() })) {
                    ForEach([1, 3, 5, 10, 15, 20, 25, 30, 45, 50], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Break", selection: Binding(get: { b.breakMin }, set: { b.breakMin = $0; app.settingsChanged() })) {
                    ForEach([5, 10, 15, 20, 25, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Daily capacity", selection: Binding(get: { b.cap }, set: { b.cap = $0; app.settingsChanged() })) {
                    ForEach([4, 6, 8, 10, 12, 14, 16, 18], id: \.self) { v in
                        Text("\(v) blocks (≈ \(String(format: "%g", Double(v * (b.workMin + b.breakMin)) / 60)) h)").tag(v)
                    }
                }
                Picker("Workday ends", selection: Binding(get: { b.workEnd }, set: { b.workEnd = $0; app.settingsChanged() })) {
                    ForEach(14...21, id: \.self) { h in Text(hourLabel(Double(h))).tag(h) }
                }
                Toggle("Weekends are reset days (no work blocks)", isOn: Binding(get: { b.weekendsOff }, set: { b.weekendsOff = $0; app.settingsChanged() }))
                Toggle("Lock the screen when the workday ends", isOn: Binding(get: { b.eveningLock }, set: { b.eveningLock = $0; app.settingsChanged() }))
            }
            Section("Where you live (for sunrise and sunset)") {
                HStack {
                    TextField("City, State or City, Country", text: $m.place).onSubmit(find)
                    Button(finding ? "Finding…" : "Find", action: find).disabled(finding || m.place.isEmpty)
                }
                Text(placeMsg ?? String(format: "Using %.2f, %.2f%@", m.cat.latitude, m.cat.longitude, b.d.string(forKey: "placeName") == nil ? " (a guess from your time zone)" : ""))
                    .font(.caption).foregroundStyle(placeMsg == nil ? Color.secondary : warm)
            }
            Section("Focus") {
                Toggle("Focus guard: only work apps during work blocks", isOn: Binding(get: { b.focusGuard }, set: { b.focusGuard = $0 }))
                Button("Edit allowed apps…") { app.editAllow() }
            }
            Section("Mac") {
                Toggle("Open SpinBreak at login", isOn: Binding(get: { login }, set: { on in
                    guard sandbox == nil else { return }
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    login = SMAppService.mainApp.status == .enabled
                }))
                Button("Test the reminder ding (1 min)") { app.testDing() }
                Text("Break-over alerts go through Reminders, so they also reach your iPhone and Apple Watch.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func find() {
        finding = true; placeMsg = nil
        m.findPlace { err in finding = false; placeMsg = err }
    }
}

// MARK: Morning

struct MorningTab: View {
    @ObservedObject var m: SettingsModel
    @State private var draft = ""
    var list: [String] { m.cat.checklist ?? Engine.morningChecklist }

    var body: some View {
        Form {
            Section {
                Text("Each workday opens on this list, next to your morning brief. Check everything off to start work. Keep it short and honest.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Morning checklist") {
                ForEach(Array(list.enumerated()), id: \.offset) { i, item in
                    HStack {
                        TextField("", text: Binding(get: { item }, set: { v in var l = list; l[i] = v; m.cat.checklist = l }))
                        Button { var l = list; l.swapAt(i, i - 1); m.cat.checklist = l } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(i == 0)
                        Button { var l = list; l.swapAt(i, i + 1); m.cat.checklist = l } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(i == list.count - 1)
                        Button { var l = list; l.remove(at: i); m.cat.checklist = l } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add an item, e.g. 🚰 Water bottle filled", text: $draft).onSubmit(add)
                    Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
    func add() {
        let t = draft.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        m.cat.checklist = list + [t]; draft = ""
    }
}

// MARK: Your AI

struct AITab: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var b: Brain
    let app: AppDelegate
    @State private var copied = false
    @State private var style = ""

    var body: some View {
        Form {
            Section("Set up by your own agent") {
                HStack(alignment: .center, spacing: 12) {
                    Button(copied ? "Copied ✓" : "Copy setup prompt") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(AISetup.setupPrompt(dir: b.dir, rooms: nil), forType: .string); copied = true
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Paste it into Claude Code, Codex, or whatever you use. It interviews you and does the rest. Run it again any time to start over.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !m.importMsg.isEmpty { Text(m.importMsg).font(.callout).foregroundStyle(m.importMsg.hasPrefix("⚠️") ? warm : .primary).fixedSize(horizontal: false, vertical: true) }
            }
            Section("Your morning brief") {
                TimelineView(.periodic(from: .now, by: 2)) { _ in Text(writer).font(.callout).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    if app.briefScript != nil {
                        Button(b.briefRunning ? "Writing…" : "Write today's now") { app.rewriteBriefing() }.disabled(b.briefRunning)
                        Button("Show the log") { NSWorkspace.shared.open(b.dir.appendingPathComponent("brief.log")) }
                    }
                    Button("Open the SpinBreak folder") { NSWorkspace.shared.open(b.dir) }
                }
                Text("How it should be written. Your agent wrote this; change anything. It's read fresh every morning.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $style).font(.body).frame(minHeight: 130)
                    .onChange(of: style) { _, v in b.briefStyle = v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : v }
            }
            Section("Using a chat AI that can't reach this Mac") {
                HStack {
                    Button("Paste its setup answer") { m.previewPaste(); if m.pending != nil { m.confirmImport(); style = b.briefStyle ?? "" } }
                    Button("Copy today's brief request") { app.copyBriefRequest() }
                    Button("Paste today's brief") { app.pasteBrief() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { style = b.briefStyle ?? "" }
        .onReceive(m.$importMsg) { _ in style = b.briefStyle ?? "" }
    }

    var writer: String {
        guard app.briefScript != nil else { return "No brief writer yet. Your agent sets one up from the setup prompt." }
        if b.briefRunning { return "Writing today's brief now…" }
        guard let st = b.briefStatus, st.kind == "morning" else { return "Your agent's brief.sh writes it each morning after 5." }
        let t = (st.finished ?? st.started).formatted(date: .abbreviated, time: .shortened)
        return st.state == "ok" ? "Written by your agent's brief.sh. Last run \(t)." : "⚠️ Last run \(t) failed: \(st.detail). It tries again by itself; the log says more."
    }
}

// MARK: Household

struct HouseholdTab: View {
    @ObservedObject var m: SettingsModel
    let app: AppDelegate
    @State private var name = Household.name
    @State private var status = ""
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text("Live with someone who also uses SpinBreak? Share one calendar and your spinners split the cleaning: a room one of you is on, or did this week, doesn't come up for the other; a rough room comes back for whoever spins next; and while one of you is cleaning, the other's spinner leans toward a different room so you clean at the same time.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("You") {
                TextField("Your name (shown on the shared calendar)", text: $name)
                    .onSubmit { Household.name = name }.onChange(of: name) { _, v in Household.name = v }
            }
            Section("The shared calendar") {
                if let c = app.ding.homeCalendar {
                    Label("Connected to “\(c.title)” (\(c.source.title))", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                    let n = Set(app.b.household.map(\.at)).count
                    Text(n == 0 ? "Nothing from anyone else yet. Once the other person accepts the share and cleans a room, it shows up here."
                                : "\(n) room\(n == 1 ? "" : "s") from the rest of the house this week.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Only ONE of you creates it. If someone already shared “SpinBreak Home” with you, don't press this: accept their invite instead (it's in the Calendar app or your email), and it connects by itself.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Create the “SpinBreak Home” calendar") {
                        status = app.ding.makeHomeCalendar() == nil
                            ? (app.ding.calOK ? "Couldn't make it. Is iCloud Calendar turned on in System Settings › Apple ID › iCloud?" : "SpinBreak needs Calendar access first (System Settings › Privacy & Security › Calendars).")
                            : "Made it. Now share it (below)."
                        app.refreshHousehold()
                    }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(warm) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Then, in the Calendar app:").font(.callout).bold()
                    Text("1. Right-click “SpinBreak Home” in the sidebar › Share Calendar…")
                    Text("2. Add the other person's Apple ID email, make sure their access is “View & Edit”, and press Done.")
                    Text("3. They accept the invite (Calendar app or email), make sure it's checked, and that's it. Their SpinBreak finds it by name.")
                }.font(.caption).foregroundStyle(.secondary)
                Button("Open Calendar") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
            }
            Section("Rooms") {
                let rooms = m.cat.activities.filter(Engine.isRoom)
                Text(rooms.isEmpty ? "You have no rooms yet. Rooms are activities whose id starts with clean- (your AI setup makes them)."
                     : rooms.map { "\($0.emoji) \($0.name)" }.joined(separator: " · ")).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(copied ? "Copied ✓" : "Copy my rooms (for the other person's AI setup)") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Household.roomList(m.cat), forType: .string); copied = true
                }.disabled(rooms.isEmpty)
                Text("Rooms match by id, or by the room's name if the ids differ (“Kitchen reset” and “Deep-clean the kitchen” are the same room).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { app.refreshHousehold() }
    }
}
