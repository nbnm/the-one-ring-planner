import SwiftUI
import RingCore

struct TaskSlotSheet: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let request: TaskSlotRequest
    @State private var startDay: Date
    @State private var notBefore = -1
    @State private var minutes: Int
    @State private var weekends = false
    @State private var fitEarlierGaps = true
    @State private var searchOptions = false
    @State private var excluded = Set<String>()
    @State private var refresh = 0
    @State private var slots: [TaskTimeSlot] = []
    @State private var loading = true
    @State private var accepting = false
    @State private var choosingCalendar = false
    @State private var message: String?
    @State private var assessment: TaskSlotAssessment?
    init(request: TaskSlotRequest) { self.request = request; _startDay = State(initialValue: request.day); _minutes = State(initialValue: request.minutes) }
    private struct Search: Equatable { let day: Date; let minute: Int; let duration: Int; let weekends: Bool; let refresh: Int; let automaticFit: Bool }
    private var earliest: Int { notBefore < 0 ? store.settings.workStart : notBefore }
    private var search: Search { Search(day: startDay, minute: earliest, duration: minutes, weekends: weekends, refresh: refresh, automaticFit: fitEarlierGaps && request.task.allowsSplitting) }
    var body: some View {
        Group {
            if choosingCalendar { TaskSlotCalendarChooser(request: request, minutes: slots.first?.minutes ?? minutes, back: { choosingCalendar = false }) }
            else { automaticView }
        }
        .task(id: search) {
            guard request.minutes > 0 else { loading = false; return }
            loading = true; message = nil; slots = []; assessment = nil
            do {
                let found = try await store.findTaskSlots(request: request, starting: startDay, notBefore: earliest, minutes: minutes, weekends: weekends, excluding: excluded, automaticFit: search.automaticFit)
                guard !Task.isCancelled else { return }; slots = found
                if let first = found.first { assessment = try await store.assessTaskSlot(first, request: request, manual: false) }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
    private var automaticView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Q2 · Make time")
            Text("First available time").font(Theme.display(29))
            Text(request.task.title).font(Theme.body(14, weight: .semibold)).lineLimit(3)
            TaskTagsView(tags: request.task.tags)
            }
            DividerLine()
            if request.minutes == 0 {
                Text("This task already has its remaining effort planned.").font(Theme.body(13)).foregroundStyle(Theme.secondary)
                if let date = request.existingStart { Button("Open planned day") { store.selectedDay = date; store.page = .calendar; dismiss() }.buttonStyle(GoldButton()) }
            } else {
                if request.task.allowsSplitting { Toggle("Use an earlier gap for a shorter first block", isOn: $fitEarlierGaps).toggleStyle(.checkbox).font(Theme.body(11)) }
                DisclosureGroup("Search options", isExpanded: $searchOptions) {
                    VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DatePicker("Start looking", selection: $startDay, in: store.calendar.startOfDay(for: store.now)..., displayedComponents: .date)
                    MinutePicker(title: "Not before", minute: Binding(get: { earliest }, set: { notBefore = $0 }))
                }.environment(\.timeZone, store.calendar.timeZone)
                HStack {
                    if search.automaticFit { Text("Block: up to \(minutes) minutes") }
                    else { TaskSlotDurationPicker(task: request.task, available: request.minutes, minutes: $minutes) }
                    Spacer(); Toggle("Include weekends", isOn: $weekends).toggleStyle(.checkbox)
                }.font(Theme.body(12))
                Text("Checks the next seven workdays from the chosen date in order. Calendar events, planned tasks, routines and lunch are included. Interruption reserve is shown as a warning, so it won’t hide an otherwise free time.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                    }.padding(.top, 8)
                }.font(Theme.body(12))
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Finding the earliest free time…").font(Theme.body(13)) }.padding(.vertical, 20)
                } else if let slot = slots.first {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(store.dayTitle(slot.start)).font(Theme.body(12)).foregroundStyle(Theme.secondary)
                        Text("\(store.time(slot.start))–\(store.time(slot.end))").font(Theme.display(34)).monospacedDigit()
                        Text("\(slot.minutes) min of \(request.minutes) min not yet planned").font(Theme.body(12)).foregroundStyle(Theme.secondary)
                        if slot.minutes < request.minutes { Text("First block · \(request.minutes - slot.minutes) min will still need a time.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
                        ForEach(assessment?.warnings ?? [], id: \.self) { Text($0).font(Theme.body(11)).foregroundStyle(Theme.gold) }
                        HStack {
                            Button("Choose on calendar") { choosingCalendar = true }.buttonStyle(QuietButton())
                            Button("Next suggestion") {
                                for amount in TaskSlotPlanner.candidateLengths(task: request.task, minutes: minutes, focusMinutes: store.settings.focusMinutes, automaticFit: search.automaticFit) {
                                    excluded.insert(TaskTimeSlot(taskID: slot.taskID, start: slot.start, end: slot.start.addingTimeInterval(Double(amount * 60))).id)
                                }
                                refresh += 1
                            }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.secondary)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Theme.goldFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    Text(store.isDemo ? "Example booking keeps Google Calendar unchanged." : "Accepting adds only this task block to \(store.publicationDestinationTitle(for: slot.start)).").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                } else {
                    Text(message ?? "No automatic slot fits. Choose a time on the calendar to review the gaps and constraints.").font(Theme.body(13)).foregroundStyle(Theme.alert)
                    Button("Choose on calendar") { choosingCalendar = true }.buttonStyle(QuietButton())
                }
                if let message, !slots.isEmpty { Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert) }
            }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            }
            DividerLine()
            HStack {
                Button("Plan later") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Spacer()
                if accepting { ProgressView().controlSize(.small) }
                if let slot = slots.first {
                    Button(store.isDemo ? "Accept example slot" : "Accept & add to calendar") {
                        accepting = true; message = nil
                        Task { do { if try await store.acceptTaskSlot(slot, request: request) { dismiss() } } catch { message = error.localizedDescription }; accepting = false }
                    }.buttonStyle(GoldButton()).keyboardShortcut(.defaultAction).disabled(loading || assessment?.canBook != true)
                }
            }.padding(26)
        }.frame(width: 650, height: 660).background(Theme.background).foregroundStyle(Theme.text).font(Theme.body())
            .disabled(accepting).interactiveDismissDisabled(accepting)
    }
}

struct TaskSlotDurationPicker: View {
    let task: PlannerTask
    let available: Int
    @Binding var minutes: Int
    private var lengths: [Int] {
        let minimum = max(5, min(task.minimumBlockMinutes, available))
        let values = stride(from: minimum, through: max(minimum, available), by: 5).filter { $0 == available || available - $0 >= minimum }
        return Array(Set(values + [available])).sorted()
    }
    var body: some View {
        if task.allowsSplitting && lengths.count > 1 { Picker("Block", selection: $minutes) { ForEach(lengths, id: \.self) { Text("\($0) minutes").tag($0) } }.frame(maxWidth: 220) }
        else { Text("Block: \(minutes) minutes").font(Theme.body(12)) }
    }
}

struct TaskSlotCalendarChooser: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let request: TaskSlotRequest
    @State var minutes: Int
    let back: () -> Void
    @State private var start: Date?
    @State private var assessment: TaskSlotAssessment?
    @State private var checking = false
    @State private var accepting = false
    @State private var message: String?
    @State private var previousDay: Date?
    @State private var accepted = false
    private var slot: TaskTimeSlot? { start.map { TaskTimeSlot(taskID: request.task.id, start: $0, end: $0.addingTimeInterval(Double(minutes * 60))) } }
    private var checkKey: String { "\(start?.timeIntervalSince1970 ?? -1)|\(minutes)" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(request.task.title).font(Theme.body(14, weight: .semibold)).lineLimit(1)
                Spacer(); Button("Back to suggestion", action: back).buttonStyle(QuietButton())
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
            CalendarPage(bookingTask: request.task, proposal: slot, selectTime: { start = $0 })
            DividerLine()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 20) {
                    DatePicker("Starts", selection: Binding(get: { start ?? PlannerDate.at(store.settings.workStart, on: store.selectedDay, settings: store.settings) }, set: { start = $0 }), displayedComponents: [.date, .hourAndMinute]).frame(maxWidth: 360)
                    TaskSlotDurationPicker(task: request.task, available: request.minutes, minutes: $minutes)
                    if let slot { Text("Ends \(store.time(slot.end))").font(Theme.body(12)).foregroundStyle(Theme.secondary) }
                    Spacer()
                    Button("Plan later") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                    Button(store.isDemo ? "Book example time" : "Add to calendar") {
                        guard let slot else { return }; accepting = true; message = nil
                        Task { do { if try await store.acceptTaskSlot(slot, request: request, manual: true) { accepted = true; dismiss() } } catch { message = error.localizedDescription }; accepting = false }
                    }.buttonStyle(GoldButton()).disabled(slot == nil || assessment?.canBook != true || checking || accepting)
                }.environment(\.timeZone, store.calendar.timeZone)
                if checking { HStack { ProgressView().controlSize(.mini); Text("Checking this time…") }.font(Theme.body(11)) }
                else if let message { Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert) }
                else if let assessment {
                    ForEach(assessment.blocking, id: \.self) { Text($0).font(Theme.body(11)).foregroundStyle(Theme.alert) }
                    ForEach(assessment.warnings, id: \.self) { Text($0).font(Theme.body(11)).foregroundStyle(Theme.gold) }
                    if assessment.canBook { Text("This time is free. Google Calendar is checked again before booking.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
                } else { Text("Click a gap on the calendar, or enter a start time below. Nothing is booked until you confirm.").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 1140, height: 800).background(Theme.background).foregroundStyle(Theme.text).disabled(accepting).interactiveDismissDisabled(accepting)
            .onAppear { previousDay = store.selectedDay; store.selectedDay = request.day }
            .onDisappear { if !accepted, let previousDay { store.selectedDay = previousDay } }
            .task(id: checkKey) {
                assessment = nil; message = nil
                guard let slot else { checking = false; return }; checking = true
                do { let result = try await store.assessTaskSlot(slot, request: request, manual: true); if !Task.isCancelled { assessment = result } }
                catch { if !Task.isCancelled { message = error.localizedDescription } }
                if !Task.isCancelled { checking = false }
            }
    }
}
