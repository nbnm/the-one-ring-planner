import SwiftUI
import RingCore

struct PlanSelectionRequest: Identifiable {
    let id = UUID()
    let day: Date
}

struct PlanTaskSelectionSheet: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let request: PlanSelectionRequest
    @State private var automatic: Bool
    @State private var selected: Set<String>
    @State private var search = ""
    @State private var submitting = false
    @State private var loadingCapacity = true
    @State private var capacityError: String?
    @State private var meetingRead: PlannerStore.PlanningMeetings?
    @State private var loadedContext: ReadContext?
    @State private var showingBreakdown = false
    @State private var capacityReadID = UUID()

    private struct ReadContext: Equatable {
        let day: String
        let settings: PlanningSettings
        let calendarEnabled: Bool
        let calendarIDs: Set<String>
    }

    init(request: PlanSelectionRequest, candidates: [PlannerTask], selectedTaskIDs: [String]?) {
        self.request = request
        _automatic = State(initialValue: selectedTaskIDs == nil)
        _selected = State(initialValue: Set(selectedTaskIDs ?? candidates.map(\.id)))
    }
    private var candidates: [PlannerTask] { store.planningCandidates }
    private var working: Bool { submitting || store.buildingPlan || store.publishingCalendar }
    private var chosen: Set<String> { automatic ? Set(candidates.map(\.id)) : selected.intersection(candidates.map(\.id)) }
    private var readContext: ReadContext {
        ReadContext(day: PlannerDate.key(request.day, settings: store.settings), settings: store.settings,
                    calendarEnabled: store.calendarConnection.enabled, calendarIDs: store.calendarConnection.selectedIDs)
    }
    private var preview: PlanningPreview? {
        guard !loadingCapacity, loadedContext == readContext, let meetingRead else { return nil }
        let previous = store.planningPlan(on: request.day)
        return Scheduler().preview(day: request.day, now: store.now, tasks: store.tasks, routines: store.routines,
            settings: store.settings, meetings: meetingRead.blocks, previous: previous,
            outcomeIDs: previous?.outcomeIDs ?? [], selectedTaskIDs: automatic ? nil : chosen.sorted())
    }
    private var visible: [PlannerTask] {
        candidates.filter { search.isEmpty || ($0.title + " " + $0.tags.joined(separator: " ") + " " + $0.context).localizedCaseInsensitiveContains(search) }
    }
    private var removedPins: Int {
        guard !automatic, let plan = store.plan else { return 0 }
        return plan.blocks.filter { $0.state == .planned && $0.pinned && $0.taskID.map { !chosen.contains($0) } == true }.count
    }
    var body: some View {
        let estimate = preview
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: store.dayTitle(request.day))
                Text("Choose this day’s tasks").font(Theme.display(29))
                Text("Choose work with room for your calendar, routines and a little breathing space.").font(Theme.body(12)).foregroundStyle(Theme.secondary).lineSpacing(3)
            }
            capacitySummary(estimate)
            HStack {
                Button("Select all") { selected = Set(candidates.map(\.id)); automatic = false }.buttonStyle(QuietButton())
                Button("Clear selection") { selected = []; automatic = false }.buttonStyle(QuietButton())
                Spacer()
                Button("Use automatic selection") { automatic = true }.buttonStyle(.plain).foregroundStyle(Theme.gold)
            }.font(Theme.body(11))
            TextField("Search tasks or tags…", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("Search planning tasks")
            DividerLine()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { task in
                        Toggle(isOn: Binding(get: { chosen.contains(task.id) }, set: { checked in
                            selected = chosen
                            if checked { selected.insert(task.id) } else { selected.remove(task.id) }
                            automatic = false
                        })) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title).font(Theme.body(13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                Text("Q\(task.quadrant?.rawValue ?? 0) · \(task.quadrant?.title ?? "") · \(task.remainingMinutes ?? 0) min\(task.context.isEmpty ? "" : " · " + task.context)").font(Theme.body(10)).foregroundStyle(Theme.secondary)
                                TaskTagsView(tags: task.tags)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.toggleStyle(.checkbox).accessibilityLabel("Include \(task.title) in this day").padding(.vertical, 12)
                        DividerLine()
                    }
                    if visible.isEmpty {
                        Text(candidates.isEmpty ? "No ready tasks yet. Review priority and effort in the matrix first." : "No tasks match this search.").font(Theme.body(13)).foregroundStyle(Theme.secondary).padding(.vertical, 30)
                    }
                }
            }.frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                Text("\(chosen.count) tasks selected").font(Theme.body(12, weight: .semibold))
                Text(store.isDemo ? "Example confirmation keeps Google Calendar unchanged." : "Confirmation adds scheduled tasks and routines to \(store.publicationDestinationTitle). Work outside the draft stays unscheduled.").font(Theme.body(11)).foregroundStyle(Theme.gold)
                Text(automatic ? "Automatic selection also considers newly ready tasks when you replan." : "This selection is saved for this date and reused when you replan.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                Text("Inbox, waiting, Q4 and archived tasks stay outside automatic planning. Completed and running blocks are kept.").font(Theme.body(10)).foregroundStyle(Theme.secondary)
                if removedPins > 0 { Text("\(removedPins) pinned future block(s) will be removed by this selection.").font(Theme.body(11)).foregroundStyle(Theme.alert) }
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("Save draft") { submit(confirm: false) }.buttonStyle(.plain).foregroundStyle(Theme.gold).disabled(estimate == nil)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(working ? "Preparing…" : (store.isDemo ? "Confirm example plan" : "Confirm & add to calendar")) { submit(confirm: true) }
                    .buttonStyle(GoldButton()).keyboardShortcut(.defaultAction).disabled(estimate == nil || (!store.isDemo && store.publicationDestination == nil && store.plan?.publication == nil))
            }
        }
        .padding(26).frame(width: 680, height: 780).background(Theme.background)
        .foregroundStyle(Theme.text).font(Theme.body()).disabled(working)
        .interactiveDismissDisabled(working)
        .task(id: readContext) { await refreshCapacity() }
    }
    private func submit(confirm: Bool) {
        let selection = automatic ? nil : chosen.sorted()
        submitting = true
        Task {
            if await store.buildDraft(day: request.day, selectedTaskIDs: selection, confirmToCalendar: confirm) {
                store.page = .today; dismiss()
            }
            submitting = false
        }
    }

    @ViewBuilder private func capacitySummary(_ estimate: PlanningPreview?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let estimate {
                HStack(alignment: .top, spacing: 24) {
                    metric("Work available", minutes: estimate.availableMinutes, color: Theme.gold)
                    metric("Personal available", minutes: estimate.personalAvailableMinutes, color: Theme.gold)
                    metric("Selected effort", minutes: estimate.selectedEffortMinutes, color: Theme.text)
                    metric("Fits in draft", minutes: estimate.scheduledEffortMinutes, color: Theme.green)
                    Spacer(minLength: 0)
                    Button { showingBreakdown = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel("Show available time breakdown")
                        .popover(isPresented: $showingBreakdown, arrowEdge: .trailing) { capacityBreakdown(estimate) }
                }
                let overflow = estimate.unscheduledTasks.reduce(0) { $0 + $1.minutes }
                let routineIDs = Set(store.routines.map(\.id))
                let omittedRoutines = estimate.proposedPlan.unscheduled.filter { routineIDs.contains($0.id) }.count
                if overflow > 0 {
                    Text("\(store.duration(overflow)) of selected work stays outside this draft. Check time windows, dependencies and priority.").font(Theme.body(11)).foregroundStyle(Theme.alert)
                }
                if omittedRoutines > 0 {
                    Text(omittedRoutines == 1 ? "1 routine stays outside the draft with this selection." : "\(omittedRoutines) routines stay outside the draft with this selection.").font(Theme.body(11)).foregroundStyle(Theme.alert)
                }
                if !estimate.proposedPlan.warnings.isEmpty {
                    Text("Some fixed blocks overlap or lack transition time. Review the time breakdown before building.").font(Theme.body(11)).foregroundStyle(Theme.alert)
                }
                HStack(alignment: .top) {
                    Text(calendarCaption).font(Theme.body(10)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Refresh") { Task { await refreshCapacity() } }.buttonStyle(.plain).font(Theme.body(10)).foregroundStyle(Theme.gold)
                }
            } else if let capacityError {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.alert)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Available time couldn’t be checked").font(Theme.body(12, weight: .semibold))
                        Text(capacityError).font(Theme.body(11)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("Retry") { Task { await refreshCapacity() } }.buttonStyle(QuietButton())
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking this day’s calendar and planned activities…").font(Theme.body(12)).foregroundStyle(Theme.secondary)
                }
            }
        }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { DividerLine() }.overlay(alignment: .bottom) { DividerLine() }
    }
    private var calendarCaption: String {
        if store.isDemo { return "Example calendar · Includes lunch, routines, transitions and reserve." }
        if let readAt = meetingRead?.readAt { return "Google Calendar checked at \(store.time(readAt)) · Includes activities, transitions and reserve." }
        return "Local estimate · Google Calendar is not connected; meetings are excluded."
    }
    private func metric(_ title: String, minutes: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.body(10)).foregroundStyle(Theme.secondary)
            Text(store.duration(minutes)).font(Theme.display(25)).foregroundStyle(color).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
    private func capacityBreakdown(_ estimate: PlanningPreview) -> some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text("Where the time goes").font(Theme.display(23))
            Text(store.dayTitle(request.day)).font(Theme.body(11)).foregroundStyle(Theme.secondary)
            breakdownRow("Workday", estimate.workMinutes)
            DividerLine()
            if estimate.elapsedMinutes > 0 { breakdownRow("Time already passed", estimate.elapsedMinutes) }
            breakdownRow("Calendar commitments", estimate.calendarMinutes)
            breakdownRow("Lunch", estimate.lunchMinutes)
            breakdownRow("Routines & activities", estimate.routineMinutes)
            if estimate.committedTaskMinutes > 0 { breakdownRow("Existing task blocks", estimate.committedTaskMinutes) }
            breakdownRow("Transitions", estimate.transitionMinutes)
            breakdownRow("Interruption reserve", estimate.reserveMinutes)
            DividerLine()
            breakdownRow("Work available", estimate.availableMinutes)
            breakdownRow("Personal available", estimate.personalAvailableMinutes)
            Text("Overlaps count once. Available time is measured before adding new task blocks. Flexible routines can yield to selected work; Fits in draft uses the full scheduling rules.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
            if estimate.reserveShortfallMinutes > 0 {
                Text("The day has \(store.duration(estimate.reserveShortfallMinutes)) less reserve than requested.").font(Theme.body(11)).foregroundStyle(Theme.alert)
            }
            ForEach(estimate.unscheduledTasks) { item in
                Text("\(item.title): \(item.reason)").font(Theme.body(11)).foregroundStyle(Theme.alert)
            }
            ForEach(estimate.proposedPlan.warnings, id: \.self) { warning in Text(warning).font(Theme.body(11)).foregroundStyle(Theme.alert) }
          }.padding(22)
        }.frame(width: 380).frame(maxHeight: 560).background(Theme.background).foregroundStyle(Theme.text)
    }
    private func breakdownRow(_ title: String, _ minutes: Int) -> some View {
        HStack { Text(title).foregroundStyle(Theme.secondary); Spacer(); Text(store.duration(minutes)).monospacedDigit() }.font(Theme.body(12))
    }
    private func refreshCapacity() async {
        let context = readContext
        let readID = UUID(); capacityReadID = readID
        loadingCapacity = true; capacityError = nil; meetingRead = nil; loadedContext = nil
        defer { if readID == capacityReadID, context == readContext { loadingCapacity = false } }
        do {
            // Closing the chooser discards its preview, while an already authorized
            // calendar refresh can finish without leaving the shared connection cancelled.
            let readTask = Task { try await store.readPlanningMeetings(day: request.day, settings: context.settings) }
            let read = try await readTask.value
            guard !Task.isCancelled, readID == capacityReadID, context == readContext else { return }
            meetingRead = read; loadedContext = context
            await store.refreshPublishingSettings()
        } catch {
            guard !Task.isCancelled, readID == capacityReadID, context == readContext else { return }
            capacityError = error.localizedDescription
        }
    }
}
