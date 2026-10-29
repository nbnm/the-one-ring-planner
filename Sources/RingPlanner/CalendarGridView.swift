import SwiftUI
import AppKit
import RingCore

struct CalendarPage: View {
    @EnvironmentObject var store: PlannerStore
    var bookingTask: PlannerTask? = nil
    var proposal: TaskTimeSlot? = nil
    var selectTime: ((Date) -> Void)? = nil
    @StateObject private var interaction = CalendarDragInteraction()
    @StateObject private var grid = CalendarGridStore()
    @State private var week = true
    @State private var fullDay = false
    @State private var includeLocal = true
    @State private var transitions = false
    @State private var zoom = 0
    @State private var refreshID = UUID()
    private var days: [Date] { CalendarGrid.days(containing: store.selectedDay, week: week, calendar: store.calendar) }
    private var interval: DateInterval { DateInterval(start: days[0], end: store.calendar.date(byAdding: .day, value: 1, to: days.last!)!) }
    private var events: [CalendarGridEvent] {
        let loaded = grid.loadedInterval == interval && (store.isDemo || (store.calendarConnection.enabled && grid.loadedIDs == store.calendarConnection.selectedIDs))
        let google = loaded ? grid.events : []
        let plans = bookingTask != nil && loaded && !store.isDemo ? store.taskSlotDisplayPlans(CalendarRead(interval: interval, calendarIDs: store.calendarConnection.selectedIDs, events: google)) : store.plans
        var result = CalendarGrid.events(in: interval, google: google, plans: plans, tasks: store.tasks, includeLocal: includeLocal, includeTransitions: transitions, edits: store.calendarEdits, readAt: grid.lastRead)
        if let proposal, let bookingTask {
            result.append(CalendarGridEvent(id: "q2-proposal", title: bookingTask.title, context: "Proposed time", start: proposal.start, end: proposal.end, category: .task))
        }
        return result
    }
    private var startHour: Int { fullDay ? 0 : max(0, store.settings.workStart / 60 - 1) }
    private var endHour: Int { fullDay ? 24 : min(24, (store.settings.workEnd + 59) / 60 + 1) }
    private var loadKey: String { "\(interval.start.timeIntervalSince1970)|\(week)|\(store.settings.timeZone)|\(store.calendarConnection.enabled)|\(store.calendarConnection.selectedIDs.sorted())|\(store.calendarConnection.lastRead?.timeIntervalSince1970 ?? 0)|\(refreshID)|\(store.calendarGridRevision)" }
    private var rangeTitle: String {
        let format = DateFormatter(); format.calendar = store.calendar; format.timeZone = store.calendar.timeZone
        format.dateFormat = week ? "MMM d" : "EEEE, MMM d"
        let first = format.string(from: days[0])
        if !week { format.dateFormat = "yyyy"; return first + ", " + format.string(from: days[0]) }
        let last = format.string(from: days.last!); format.dateFormat = "yyyy"
        return first + " – " + last + ", " + format.string(from: days.last!)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            CalendarEditSyncPanel()
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - 12), gutter = CGFloat(58)
                let column = max(1, (width - gutter) / CGFloat(days.count))
                let allDayRows = min(3, days.map { allDayEvents(on: $0).count }.max() ?? 0)
                let overflow = days.contains { allDayEvents(on: $0).count > 3 }
                let allDayHeight = CGFloat(max(1, allDayRows)) * 25 + 12 + (overflow ? 18 : 0)
                let available = max(240, geometry.size.height - 82 - allDayHeight)
                let hourHeight: CGFloat = zoom == 0 ? max(36, (available - 16) / CGFloat(endHour - startHour)) : zoom == 1 ? 72 : 104
                VStack(spacing: 0) {
                    dayHeaders(gutter: gutter, column: column)
                    allDayRow(gutter: gutter, column: column, height: allDayHeight)
                    DividerLine()
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            CalendarHourRuler(startHour: startHour, endHour: endHour, hourHeight: hourHeight).frame(width: gutter)
                            ForEach(days, id: \.self) { day in
                                CalendarDayColumn(day: day, events: events, startHour: startHour, endHour: endHour, hourHeight: hourHeight, week: week, selectTime: selectTime)
                                    .frame(width: column)
                            }
                        }.frame(width: width, alignment: .leading)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(GeometryReader { g in Color.clear.preference(key: CalendarViewportKey.self, value: g.frame(in: .named(PlannerDragSpace.workspace))) })
                }.onAppear { configureInteraction(hourHeight) }
                    .onChange(of: hourHeight) { _, value in configureInteraction(value) }
                    .onChange(of: startHour) { _, _ in configureInteraction(hourHeight) }
                    .onChange(of: store.settings.timeZone) { _, _ in configureInteraction(hourHeight) }
            }
            if bookingTask != nil || (!fullDay && hasOutsideEvents) { footer }
        }.background(Theme.background)
        .environmentObject(interaction)
        .onPreferenceChange(CalendarDayFramesKey.self) { interaction.frames = $0 }
        .onPreferenceChange(CalendarViewportKey.self) { interaction.viewport = $0 }
        .onChange(of: loadKey) { _, _ in interaction.cancel() }
        .task(id: loadKey) {
            await grid.load(interval, connection: store.calendarConnection, demo: store.isDemo, examples: store.calendarGridDemoEvents)
            if bookingTask == nil { store.calendarDisplayError = grid.message }
        }
    }
    private func configureInteraction(_ hourHeight: CGFloat) { interaction.startHour = startHour; interaction.scale = hourHeight / 60; interaction.calendar = store.calendar }
    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text(bookingTask == nil ? "Calendar" : "Choose a time").font(Theme.display(30))
                Button("Today") { store.selectedDay = store.now }.buttonStyle(QuietButton())
                HStack(spacing: 0) {
                    Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 30) }.accessibilityLabel(week ? "Previous calendar week" : "Previous calendar day")
                    Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 30) }.accessibilityLabel(week ? "Next calendar week" : "Next calendar day")
                }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                Text(rangeTitle).font(Theme.body(16, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 10)
                Picker("Calendar view", selection: $week) { Text("Day").tag(false); Text("Week").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 135)
            }
            HStack(spacing: 14) {
                legend("Tasks", tint: CalendarEventStyle.tint(.task))
                legend("Routines", tint: CalendarEventStyle.tint(.routine))
                legend("Meetings", tint: CalendarEventStyle.tint(.meeting))
                Spacer()
                Menu {
                    Picker("Visible hours", selection: $fullDay) { Text("Workday").tag(false); Text("24 hours").tag(true) }
                    Picker("Zoom", selection: $zoom) { Text("Fit day").tag(0); Text("Comfortable").tag(1); Text("Detailed").tag(2) }
                    Toggle("Show local plans", isOn: $includeLocal)
                    Toggle("Show transition buffers", isOn: $transitions)
                    Divider()
                    Button("Calendar settings") { store.page = .settings }
                } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 24, height: 24) }.menuStyle(.borderlessButton).fixedSize().help("Calendar display options").accessibilityLabel("Calendar display options")
                Button { refreshID = UUID(); Task { await store.calendarConnection.refresh(day: store.selectedDay, settings: store.settings) } } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }.buttonStyle(.plain).disabled(grid.loading).help("Refresh calendar").accessibilityLabel("Refresh calendar grid")
            }.font(Theme.body(11)).foregroundStyle(Theme.secondary)
        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
    }
    private func dayHeaders(gutter: CGFloat, column: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .trailing, spacing: 4) { Text(zoneAbbreviation).font(Theme.body(9)); Text("all-day").font(Theme.body(9)) }.foregroundStyle(Theme.secondary).frame(width: gutter - 10, alignment: .trailing).padding(.trailing, 10)
            ForEach(days, id: \.self) { day in
                Button {
                    store.selectedDay = day
                    if week { week = false }
                } label: {
                    VStack(spacing: 4) {
                        Text(shortWeekday(day)).font(Theme.body(10, weight: .semibold)).tracking(0.7)
                        Text("\(store.calendar.component(.day, from: day))").font(Theme.body(20, weight: .semibold))
                            .frame(width: 34, height: 34).background(store.calendar.isDate(day, inSameDayAs: store.now) ? Theme.gold : .clear, in: Circle())
                            .foregroundStyle(store.calendar.isDate(day, inSameDayAs: store.now) ? Theme.background : Theme.text)
                        Text(occupiedDescription(day)).font(Theme.body(9)).foregroundStyle(Theme.secondary).lineLimit(1)
                            .help("Busy time within your configured work hours. Overlaps are counted once; free events are excluded.")
                    }.frame(width: column, height: 82)
                }.buttonStyle(.plain).help("Open \(store.dayTitle(day))" + clockChangeNotice(day)).accessibilityLabel("Open calendar day \(store.dayTitle(day))").accessibilityValue(occupiedDescription(day))
            }
        }
    }
    private func allDayEvents(on day: Date) -> [CalendarGridEvent] {
        let end = store.calendar.date(byAdding: .day, value: 1, to: day)!
        return events.filter { $0.allDay && $0.start < end && $0.end > day }
    }
    private func allDayRow(gutter: CGFloat, column: CGFloat, height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: gutter, height: height)
            ForEach(days, id: \.self) { day in
                let values = allDayEvents(on: day)
                VStack(spacing: 3) {
                    ForEach(values.prefix(3)) { event in CalendarGridCard(event: event, height: 22, compact: true).frame(height: 22) }
                    if values.count > 3 { CalendarAllDayOverflow(events: Array(values.dropFirst(3))) }
                }.padding(.horizontal, 3).padding(.vertical, 5).frame(width: column, height: height, alignment: .top)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1) }
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 12) {
            if bookingTask != nil { Text("Click a gap to choose a time").font(Theme.body(10)) }
            Spacer()
            if !fullDay && hasOutsideEvents { Button("Show events outside workday") { fullDay = true }.buttonStyle(.plain).foregroundStyle(Theme.gold).font(Theme.body(10)) }
        }.foregroundStyle(Theme.secondary).padding(.horizontal, 24).padding(.vertical, 12).background(Theme.sidebar.opacity(0.3))
    }
    private var hasOutsideEvents: Bool {
        days.contains { day in CalendarGrid.placements(on: day, events: events, calendar: store.calendar).contains { $0.startMinute < Double(startHour * 60) || $0.endMinute > Double(endHour * 60) } }
    }
    private var zoneAbbreviation: String { store.calendar.timeZone.abbreviation(for: store.selectedDay) ?? "Local" }
    private func occupiedDescription(_ day: Date) -> String {
        if grid.loading { return "Loading…" }
        let loaded = store.isDemo || (grid.loadedInterval == interval && grid.loadedIDs == store.calendarConnection.selectedIDs && store.calendarConnection.enabled)
        return store.duration(CalendarGrid.occupiedMinutes(on: day, events: events, settings: store.settings)) + (loaded ? " occupied" : " in local plans")
    }
    private func clockChangeNotice(_ day: Date) -> String {
        let end = store.calendar.date(byAdding: .day, value: 1, to: day)!
        let hours = Int(end.timeIntervalSince(day) / 3600)
        return hours == 24 ? "" : " · Clock change: \(hours)-hour day. Event height shows elapsed duration."
    }
    private func shortWeekday(_ day: Date) -> String { let f = DateFormatter(); f.calendar = store.calendar; f.timeZone = store.calendar.timeZone; f.dateFormat = "EEE"; return f.string(from: day).uppercased() }
    private func move(_ direction: Int) { store.dateChanged(direction * (week ? 7 : 1)) }
    private func legend(_ text: String, tint: Color) -> some View { HStack(spacing: 5) { Circle().fill(tint).frame(width: 6, height: 6); Text(text) } }
}

private struct CalendarHourRuler: View {
    let startHour: Int
    let endHour: Int
    let hourHeight: CGFloat
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background
            ForEach(startHour...endHour, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).font(Theme.body(10)).monospacedDigit().foregroundStyle(Theme.secondary)
                    .padding(.trailing, 9).offset(y: CGFloat(hour - startHour) * hourHeight + 1)
            }
        }.frame(height: CGFloat(endHour - startHour) * hourHeight + 16)
    }
}

private struct CalendarDayColumn: View {
    @EnvironmentObject var interaction: CalendarDragInteraction
    @EnvironmentObject var store: PlannerStore
    let day: Date
    let events: [CalendarGridEvent]
    let startHour: Int
    let endHour: Int
    let hourHeight: CGFloat
    let week: Bool
    var selectTime: ((Date) -> Void)? = nil
    private var height: CGFloat { CGFloat(endHour - startHour) * hourHeight + 16 }
    private var scale: CGFloat { hourHeight / 60 }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Theme.surface
                if selectTime != nil { bookingSurface }
                workHoursShade
                Canvas { context, size in
                    for half in 0...((endHour - startHour) * 2) {
                        let y = CGFloat(half) * hourHeight / 2 + 8
                        var path = Path(); path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(Theme.line.opacity(half.isMultiple(of: 2) ? 0.9 : 0.35)), lineWidth: 0.5)
                    }
                    var vertical = Path(); vertical.move(to: .zero); vertical.addLine(to: CGPoint(x: 0, y: size.height)); context.stroke(vertical, with: .color(Theme.line), lineWidth: 1)
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(CalendarGrid.placements(on: day, events: events, calendar: store.calendar)) { placement in
                    let from = max(Double(startHour * 60), placement.startMinute), to = min(Double(endHour * 60), placement.endMinute)
                    if from < to {
                        let cardHeight = max(1, CGFloat(to - from) * scale - 1)
                        let laneWidth = (geometry.size.width - 6) / CGFloat(placement.laneCount)
                        CalendarGridCard(event: placement.event, height: cardHeight, compact: week)
                            .allowsHitTesting(selectTime == nil)
                            .frame(width: max(1, laneWidth - 2), height: cardHeight)
                            .offset(x: 3 + CGFloat(placement.lane) * laneWidth, y: 8 + CGFloat(from - Double(startHour * 60)) * scale)
                    }
                }
                if let preview = interaction.preview {
                    let e = preview.event
                    let ghost = CalendarGridEvent(id: "drag-preview", title: e.title, start: preview.interval.start, end: preview.interval.end, category: e.category)
                    ForEach(CalendarGrid.placements(on: day, events: [ghost], calendar: store.calendar)) { p in
                        let from = max(Double(startHour * 60), p.startMinute), to = min(Double(endHour * 60), p.endMinute)
                        if from < to {
                            CalendarDragGhost(event: ghost, width: geometry.size.width - 8, height: CGFloat(to - from) * scale - 1)
                                .offset(x: 3, y: 8 + CGFloat(from - Double(startHour * 60)) * scale).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }
                if store.calendar.isDate(day, inSameDayAs: store.now) {
                    let minute = CalendarGrid.minute(store.now, on: day, calendar: store.calendar)
                    if minute >= Double(startHour * 60) && minute <= Double(endHour * 60) {
                        HStack(spacing: 0) { Circle().fill(Color.red).frame(width: 7, height: 7); Rectangle().fill(Color.red).frame(height: 1) }
                            .offset(y: 8 + CGFloat(minute - Double(startHour * 60)) * scale - 3).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }.clipped()
                .preference(key: CalendarDayFramesKey.self, value: [day: geometry.frame(in: .named(PlannerDragSpace.workspace))])
        }.frame(height: height)
    }
    private var bookingSurface: some View {
        VStack(spacing: 0) {
            ForEach(0..<((endHour - startHour) * 2), id: \.self) { half in
                let base = startHour * 60 + half * 30
                let date = PlannerDate.at(base, on: day, settings: store.settings)
                Color.clear.contentShape(Rectangle()).frame(height: hourHeight / 2)
                    .onTapGesture { location in
                        let minute = min(1435, max(0, base + Int((Double(location.y / scale) / 5).rounded()) * 5))
                        selectTime?(PlannerDate.at(minute, on: day, settings: store.settings))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Choose " + store.scheduledDate(date, includeYear: true))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { selectTime?(date) }
            }
        }.padding(.top, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var workHoursShade: some View {
        ZStack(alignment: .top) {
            if store.calendar.isDateInWeekend(day) { Theme.sidebar.opacity(0.45) }
            Rectangle().fill(Theme.sidebar.opacity(0.55)).frame(height: max(0, CGFloat(store.settings.workStart - startHour * 60) * scale + 8))
            Rectangle().fill(Theme.sidebar.opacity(0.55)).frame(height: max(0, CGFloat(endHour * 60 - store.settings.workEnd) * scale + 8)).frame(maxHeight: .infinity, alignment: .bottom)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private enum CalendarEventStyle {
    static func tint(_ category: CalendarGridEvent.Category) -> Color {
        switch category {
        case .task: return Color(nsColor: Theme.rgb(0xBE3D36))
        case .routine: return Color(nsColor: Theme.rgb(0x16764D))
        case .meeting: return Color(nsColor: Theme.rgb(0x2468C9))
        case .pause, .transition: return Theme.secondary
        }
    }
}
private struct CalendarAllDayOverflow: View {
    @EnvironmentObject var store: PlannerStore
    @State private var showing = false
    let events: [CalendarGridEvent]
    var body: some View {
        Button("+\(events.count) more") { showing = true }.buttonStyle(.plain).font(Theme.body(10)).foregroundStyle(Theme.gold)
            .popover(isPresented: $showing) {
                ScrollView { VStack(alignment: .leading, spacing: 7) { ForEach(events) { CalendarGridCard(event: $0, height: 30, compact: false).frame(height: 30) } }.padding(16) }.frame(width: 340, height: min(340, CGFloat(events.count) * 37 + 32)).environmentObject(store)
            }
    }
}
private struct CalendarGridCard: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var interaction: CalendarDragInteraction
    @State private var hovered = false
    @State private var showingDetails = false
    let event: CalendarGridEvent
    let height: CGFloat
    let compact: Bool
    private var tint: Color { CalendarEventStyle.tint(event.category) }
    private var solid: Bool { !event.isLocal && event.status != .free }
    private var showsTime: Bool { !event.allDay && height >= (compact ? 46 : 35) }
    private var titleLines: Int { height >= 92 ? 3 : height >= 60 || (!showsTime && height >= 32) ? 2 : 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
                if height >= 16 {
                    Text(event.title).font(Theme.body(compact ? 10 : 12, weight: .semibold)).lineLimit(titleLines).strikethrough(event.status == .completed).frame(maxWidth: .infinity, alignment: .leading)
                }
                if showsTime {
                    Text("\(store.time(event.start))–\(store.time(event.end)) · \(store.duration(event.minutes))").font(Theme.body(compact ? 9 : 10)).lineLimit(1).opacity(0.9)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 6).padding(.vertical, height < 20 ? 0 : 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(solid ? Color.white : Theme.text)
                .background(solid ? tint : tint.opacity(event.category == .transition ? 0.05 : 0.11), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.8), style: StrokeStyle(lineWidth: event.isLocal ? 1 : 0.5, dash: event.isLocal ? [3, 2] : [])))
                .opacity(event.status == .completed || event.status == .interrupted ? 0.65 : 1)
                .contentShape(Rectangle()).clipped()
        .onTapGesture { showingDetails = true }
        .accessibilityAddTraits(.isButton)
        .opacity(interaction.preview?.event.id == event.id ? 0.35 : 1)
        .overlay {
            if store.canEditCalendarEvent(event) {
                ZStack {
                    if hovered && height >= 16 {
                        VStack { Capsule().fill(solid ? .white.opacity(0.7) : tint).frame(width: 18, height: 2); Spacer(minLength: 0); Capsule().fill(solid ? .white.opacity(0.7) : tint).frame(width: 18, height: 2) }.padding(.vertical, 2).allowsHitTesting(false)
                    }
                    CalendarDragSurface(title: event.title, open: { showingDetails = true }, begin: { interaction.begin(event, edge: $0, at: $1) }, move: { interaction.move(to: $0) }, finish: { point in
                        if let result = interaction.finish(at: point) { Task { await store.editCalendarEvent(result.event, start: result.interval.start, end: result.interval.end) } }
                    }, cancel: { interaction.cancel() })
                }
            }
        }.onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .help("\(event.title)\n\(event.allDay ? "All day" : "\(store.time(event.start))–\(store.time(event.end)) · \(store.duration(event.minutes))")\n\(event.status.rawValue)\n\(event.context)")
        .accessibilityLabel("\(event.title), \(event.allDay ? "all day" : "\(store.time(event.start)) to \(store.time(event.end)), \(store.duration(event.minutes))"), \(event.status.rawValue)")
        .accessibilityAction { showingDetails = true }
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) { CalendarGridEventDetails(event: event) { showingDetails = false }.environmentObject(store) }
    }
}

private struct CalendarGridEventDetails: View {
    @EnvironmentObject var store: PlannerStore
    @State private var editingTime = false
    let event: CalendarGridEvent
    let close: () -> Void
    private var allDayDates: String {
        let format = DateFormatter(); format.calendar = store.calendar; format.timeZone = store.calendar.timeZone; format.dateStyle = .medium; format.timeStyle = .none
        let last = max(event.start, event.end.addingTimeInterval(-1))
        return format.string(from: event.start) + (store.calendar.isDate(event.start, inSameDayAs: last) ? "" : " – " + format.string(from: last))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Circle().fill(CalendarEventStyle.tint(event.category)).frame(width: 9, height: 9); Text(event.status.rawValue).font(Theme.body(11)).foregroundStyle(Theme.secondary); Spacer(); Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close event details") }
            Text(event.title).font(Theme.display(23)).fixedSize(horizontal: false, vertical: true)
            if event.allDay {
                Text("All day · \(allDayDates)").font(Theme.body(13))
            } else {
                Text("\(store.scheduledDate(event.start, includeYear: true)) \(store.calendar.timeZone.abbreviation(for: event.start) ?? "")\n\(store.scheduledDate(event.end, includeYear: true)) \(store.calendar.timeZone.abbreviation(for: event.end) ?? "")").font(Theme.body(13)).monospacedDigit()
                Text(store.duration(event.minutes)).font(Theme.body(20, weight: .semibold)).foregroundStyle(CalendarEventStyle.tint(event.category))
                if store.calendar.timeZone.secondsFromGMT(for: event.start) != store.calendar.timeZone.secondsFromGMT(for: event.end) { Text("The clock changes during this event. Its height shows elapsed duration.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            }
            if !event.context.isEmpty { Label(event.context, systemImage: "calendar").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            if event.isLocal { Text("This is a local draft. Moving or resizing it publishes this occurrence to Google Calendar.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            if event.status == .free { Text("This event does not reserve busy time.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            if store.canEditCalendarEvent(event) {
                Button("Move or resize…") { editingTime = true }.buttonStyle(QuietButton())
                    .sheet(isPresented: $editingTime) { CalendarTimeEditor(event: event).environmentObject(store) }
                Text("Drag the event to move it. Drag either edge to change its duration. Routine edits affect this occurrence only.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            }
            HStack {
                if let task = store.tasks.first(where: { $0.id == event.taskID }) { Button("Open task") { close(); store.editingTask = task }.buttonStyle(QuietButton()) }
                if let plan = store.plans.first(where: { $0.id == event.planID }) { Button("Open day plan") { close(); store.openHistoryPlan(plan) }.buttonStyle(QuietButton()) }
            }
            Text(store.settings.timeZone).font(Theme.body(10)).foregroundStyle(Theme.secondary)
        }.padding(22).frame(width: 340).background(Theme.background).foregroundStyle(Theme.text)
    }
}

private struct CalendarDragGhost: View {
    @EnvironmentObject var store: PlannerStore
    let event: CalendarGridEvent
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title).font(Theme.body(10, weight: .semibold)).lineLimit(1)
            Text("\(store.time(event.start))–\(store.time(event.end)) · \(event.minutes)m").font(Theme.body(9)).lineLimit(1)
        }.padding(4).frame(width: max(1, width), height: max(1, height), alignment: .topLeading)
            .background(CalendarEventStyle.tint(event.category).opacity(0.9), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.8), lineWidth: 1)).clipped()
    }
}
