import SwiftUI
import AppKit
import RingCore

struct MainView: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var quadrantExpanded: Bool { store.page == .matrix && store.expandedQuadrant != nil }
    var body: some View {
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            if !quadrantExpanded {
                sidebar.frame(width: 184)
                Rectangle().fill(Theme.line).frame(width: 1)
            }
            VStack(spacing: 0) {
                Group {
                    switch store.page {
                    case .today: TodayView()
                    case .calendar: CalendarPage()
                    case .matrix: MatrixView()
                    case .routines: RoutinesView()
                    case .meetings: MeetingPage(meetings: store.meetings)
                    case .review: ReviewView()
                    case .history: TaskHistoryView()
                    case .settings: PreferencesView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !quadrantExpanded && store.page != .meetings && store.page != .calendar {
                Rectangle().fill(Theme.line).frame(width: 1)
                InboxSidebar().frame(width: 306)
            }
          }
          PlannerStatusBar(alerts: store.eventAlerts)
        }
        .font(Theme.body()).foregroundStyle(Theme.text).background(Theme.background)
        .frame(minWidth: 1160, minHeight: 700)
        .coordinateSpace(name: PlannerDragSpace.workspace)
        .onPreferenceChange(PriorityDropRegionsKey.self) { store.priorityDropRegions = $0 }
        .onChange(of: store.page) { _, page in
            store.taskDrag = nil
            if page != .matrix && store.expandedQuadrant != nil { store.closeExpandedQuadrant() }
        }
        .overlay { if let drag = store.taskDrag { TaskDragPreview(drag: drag) } }
        .overlay { if let routine = store.celebration { RoutineCelebration(kind: routine.kind, title: routine.title) { store.celebration = nil } } }
        .overlay(alignment: .bottom) {
            if let feedback = store.taskCelebration {
                TaskCompletionToast(feedback: feedback).id(feedback.id).padding(.bottom, 46).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.taskCelebration?.id)
        .sheet(item: $store.editingTask) { TaskEditor(task: $0) }
        .sheet(item: $store.priorityReview) { PriorityReviewSheet(request: $0) }
        .sheet(item: $store.captureReview) { CaptureReviewSheet(review: $0) }
        .sheet(item: $store.planningSelection) { request in
            PlanTaskSelectionSheet(request: request, candidates: store.planningCandidates,
                selectedTaskIDs: store.plans.first { $0.id == PlannerDate.key(request.day, settings: store.settings) }?.selectedTaskIDs)
        }
        .sheet(item: Binding(get: { store.priorityReview == nil && store.editingTask == nil && store.planningSelection == nil ? store.taskSlotRequest : nil }, set: { store.taskSlotRequest = $0 })) { TaskSlotSheet(request: $0) }
        .alert("Your changes need attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .task(id: store.dayKey + store.settings.timeZone) {
            if !store.isDemo { await store.calendarConnection.refresh(day: store.selectedDay, settings: store.settings) }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { RingMark(size: 36); VStack(alignment: .leading, spacing: 4) { Text("THE ONE RING").font(Theme.body(10, weight: .bold)).tracking(1); Text("PLANNER").font(Theme.body(10, weight: .semibold)).tracking(2.2) }.fixedSize() }
                .padding(.top, 28).padding(.bottom, 36).padding(.horizontal, 19)
            ForEach(PlannerStore.Page.allCases.filter { $0 != .settings }, id: \.self) { page in
                Button { store.page = page } label: {
                    HStack(spacing: 11) {
                        if page == .meetings { EyeMark().frame(width: 18, height: 18) }
                        else { Image(systemName: page.icon).font(.system(size: 15)).frame(width: 18) }
                        Text(page.rawValue).font(Theme.body(13, weight: store.page == page ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                        .foregroundStyle(store.page == page ? Theme.gold : Theme.secondary)
                        .background(store.page == page ? Theme.goldFill : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 3)
            }
            Spacer()
            Button { AppActions.capture() } label: { Label("Capture", systemImage: "plus").font(Theme.body(13)).foregroundStyle(Theme.secondary).padding(.horizontal, 24).padding(.vertical, 12) }.buttonStyle(.plain).help("Quick capture · Control Option Space")
            Button { store.page = .settings } label: { Label("Settings", systemImage: "slider.horizontal.3").font(Theme.body(13)).foregroundStyle(Theme.secondary).padding(24) }.buttonStyle(.plain)
        }.background(Theme.sidebar)
    }
}

struct TodayView: View {
    @EnvironmentObject var store: PlannerStore
    @State private var showTransitions = false
    private var visibleBlocks: [PlanBlock] {
        let saved = store.displayPlan?.blocks ?? []
        guard store.calendarConnection.connected,
              let meetings = try? store.calendarConnection.meetings(day: store.selectedDay, settings: store.settings) else { return saved }
        return (saved.filter { $0.kind != .meeting } + meetings).sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(title: store.dayTitle(store.selectedDay))
                            Text(store.calendar.isDate(store.selectedDay, inSameDayAs: store.now) ? "Today’s plan" : (store.calendar.isDate(store.selectedDay, inSameDayAs: store.calendar.date(byAdding: .day, value: 1, to: store.now) ?? store.now) ? "Tomorrow’s plan" : "Your day plan")).font(Theme.display(36))
                        }
                        Spacer()
                        HStack(spacing: 3) {
                            Button { store.dateChanged(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 30) }.help("Previous day")
                            Button("Today") { store.selectedDay = Date() }.font(Theme.body(11)).padding(.horizontal, 4)
                            Button { store.dateChanged(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 30) }.help("Next day")
                        }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    }
                    if store.calendarConnection.enabled && store.displayPlan == nil { CalendarAgenda(connection: store.calendarConnection) }
                    if let plan = store.displayPlan {
                        if !plan.outcomeIDs.isEmpty { outcome(plan) }
                        PlanBalanceStrip(plan: plan)
                        HStack {
                            SectionLabel(title: "Schedule")
                            Spacer()
                            Button { store.chooseTasks(for: store.selectedDay) } label: { Label("Choose tasks", systemImage: "checklist").font(Theme.body(11)) }.buttonStyle(.plain).foregroundStyle(Theme.gold).disabled(store.buildingPlan)
                            Button { store.generate() } label: { Label("Replan", systemImage: "arrow.triangle.2.circlepath").font(Theme.body(11)) }.buttonStyle(.plain).foregroundStyle(Theme.secondary).padding(.leading, 8)
                            Menu { Toggle("Show transitions", isOn: $showTransitions) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("Schedule display options").accessibilityLabel("Schedule display options")
                        }
                        VStack(spacing: 0) {
                            ForEach(visibleBlocks.filter { block in
                                (showTransitions || block.kind != .transition) && !store.tasks.contains { $0.id == block.taskID && $0.state == .done }
                            }) { block in TimelineRow(block: block) }
                        }
                        if !plan.unscheduled.isEmpty {
                            DividerLine()
                            DisclosureGroup("Unscheduled · \(plan.unscheduled.count)") {
                                ForEach(plan.unscheduled) { item in
                                    HStack { Text(item.title); Spacer(); Text("\(item.minutes)m").foregroundStyle(Theme.secondary) }.font(Theme.body(12)).padding(.vertical, 5).help(item.reason)
                                }
                            }
                        }
                    } else { emptyDay }
                    TodayCompletedTasks()
                }.padding(32)
            }
        }
    }
    private func outcome(_ plan: DayPlan) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(title: "One thing that matters")
                if let id = plan.outcomeIDs.first, let task = store.tasks.first(where: { $0.id == id }) {
                    Button { store.editingTask = task } label: { Text(task.title).font(Theme.display(21)).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                    Text(task.context.isEmpty ? "Primary outcome" : task.context).font(Theme.body(11)).foregroundStyle(Theme.secondary)
                } else {
                    Text("Choose your primary outcome").font(Theme.display(21))
                    Button("Choose in the priority matrix →") { store.page = .matrix }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gold)
                }
            }
            Spacer(minLength: 0)
            RingMark(size: 76).accessibilityHidden(true)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Theme.goldFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 18) {
            RingMark(size: 120).padding(.top, 32)
            Text("No plan for this day").font(Theme.display(30))
            HStack(spacing: 12) {
                Button { AppActions.capture() } label: { Label("Capture your first task", systemImage: "plus") }.buttonStyle(GoldButton())
                if !store.activeTasks.isEmpty || store.routines.contains(where: { $0.enabled }) {
                    Button("Choose tasks") { store.chooseTasks(for: store.selectedDay) }.buttonStyle(QuietButton())
                    Button("Build automatically") { store.generate() }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gold)
                }
            }.padding(.top, 6)
            if !store.inbox.isEmpty { Button("Prioritize your inbox →") { store.page = .matrix }.buttonStyle(.plain).foregroundStyle(Theme.gold) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DayInspector: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionLabel(title: "A little breathing room")
                if let p = store.displayPlan {
                    ZStack {
                        Circle().stroke(Theme.line, lineWidth: 8)
                        Circle().trim(from: 0, to: min(1, Double(p.plannedMinutes) / Double(max(1, p.workMinutes)))).stroke(Theme.gold, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                        VStack(spacing: 2) { Text(store.duration(p.plannedMinutes)).font(Theme.display(30)); Text("planned work").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
                    }.frame(width: 138, height: 138).frame(maxWidth: .infinity).padding(.vertical, 10).accessibilityElement(children: .combine)
                    VStack(spacing: 12) {
                        balanceRow("Work window", value: store.duration(p.workMinutes))
                        balanceRow("Meetings, lunch & gaps", value: store.duration(p.fixedMinutes))
                        balanceRow("Interruption reserve", value: store.duration(p.reserveMinutes))
                        balanceRow("Still unallocated", value: store.duration(p.freeMinutes))
                    }
                    Text("\(store.settings.reservePercent)% of available capacity stays unbooked. Transitions count as real time.").font(Theme.body(11)).foregroundStyle(Theme.secondary).lineSpacing(3)
                    if let original = store.plan { CalendarPublicationPanel(plan: original) }
                    else { Label("Scheduled in Google Calendar", systemImage: "calendar.badge.checkmark").font(Theme.body(12)).foregroundStyle(Theme.green) }
                } else {
                    RingMark(size: 100).frame(maxWidth: .infinity).padding(.vertical, 12)
                    Text("Your plan starts with a task.").font(Theme.display(20))
                    Text("Inbox captures stay out of the schedule until you confirm their priority and effort.").font(Theme.body(12)).foregroundStyle(Theme.secondary).lineSpacing(4)
                }
                DividerLine()
                HStack { SectionLabel(title: "Make room for you"); Spacer(); Button { store.page = .routines } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Configure routines") }
                ForEach(store.routines) { r in
                    HStack(spacing: 12) {
                        Image(systemName: r.kind.symbol).font(.system(size: 20)).foregroundStyle(Theme.gold).frame(width: 25)
                        VStack(alignment: .leading, spacing: 3) { Text(r.title).font(Theme.body(12, weight: .semibold)); Text("\(r.minutes) min · \(r.enabled ? r.scheduleSummary : "Not enabled")").font(Theme.body(10)).foregroundStyle(Theme.secondary) }
                    }
                }
                DividerLine()
                Label("Local workspace", systemImage: "externaldrive").font(Theme.body(12, weight: .semibold))
                Text("Tasks and drafts are saved in local Git history. Selected calendars provide meeting availability; remote Git sync is not configured.").font(Theme.body(11)).foregroundStyle(Theme.secondary).lineSpacing(4)
            }.padding(24)
        }
    }
    private func balanceRow(_ title: String, value: String) -> some View { HStack { Text(title).foregroundStyle(Theme.secondary); Spacer(); Text(value).foregroundStyle(Theme.text) }.font(Theme.body(11)) }
}

struct TimelineRow: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let block: PlanBlock
    @State private var hovered = false
    @State private var showPause = false
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(store.time(block.start)).font(Theme.body(11, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 39, alignment: .leading).padding(.top, 15)
            VStack(spacing: 0) {
                ZStack {
                    if let task, task.state != .done && task.state != .archived {
                        Button { markCompleted(task) } label: {
                            Image(systemName: "circle").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.gold).frame(width: 28, height: 30)
                        }.buttonStyle(.plain).help("Mark task completed · saved in History")
                            .accessibilityLabel("Mark \(task.title) completed")
                            .disabled(store.publishingCalendar || store.calendarEditSending)
                    } else {
                        Circle().fill(block.kind == .transition ? Theme.background : color.opacity(0.15)).frame(width: block.kind == .transition ? 7 : 28, height: block.kind == .transition ? 7 : 28)
                        if block.kind != .transition { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(color) }
                    }
                }.frame(height: block.kind == .transition ? 24 : 30).padding(.top, block.kind == .transition ? 8 : 9)
                Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let id = block.taskID {
                        Button { store.editingTask = store.tasks.first { $0.id == id } } label: { Text(block.title).font(Theme.body(13, weight: .semibold)).strikethrough(block.state == .completed).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                    } else {
                        Text(block.title).font(Theme.body(block.kind == .transition ? 11 : 13, weight: block.kind == .transition ? .regular : .semibold)).strikethrough(block.state == .completed).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    if block.pinned || block.protected { Image(systemName: block.protected ? "lock" : "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.secondary) }
                    Text("\(block.minutes)m").font(Theme.body(10)).foregroundStyle(Theme.secondary)
                }
                if block.kind != .transition {
                    if let id = block.taskID, let task = store.tasks.first(where: { $0.id == id }) { TaskTagsView(tags: task.tags) }
                    if block.state == .running { Text("In progress").font(Theme.body(10)).foregroundStyle(Theme.gold) }
                    else if !block.context.isEmpty && block.taskID == nil { Text(block.context).font(Theme.body(10)).foregroundStyle(Theme.secondary).lineLimit(1) }
                    if actionable {
                        HStack(spacing: 12) {
                            if block.state == .running {
                                if task == nil { Button { store.complete(block) } label: { Image(systemName: "checkmark.circle") }.foregroundStyle(Theme.green).help("Complete").accessibilityLabel("Complete \(block.title)") }
                                Button { showPause = true } label: { Image(systemName: "pause.circle") }.help("Continue later").accessibilityLabel("Pause \(block.title)")
                            } else {
                                Button { store.start(block) } label: { Image(systemName: "play.fill") }.foregroundStyle(Theme.gold).help("Start").accessibilityLabel("Start \(block.title)")
                                if task == nil { Button { store.complete(block) } label: { Image(systemName: "checkmark.circle") }.foregroundStyle(Theme.green).help("Complete").accessibilityLabel("Complete \(block.title)") }
                                Button { store.pin(block) } label: { Image(systemName: block.pinned ? "pin.slash" : "pin") }.help(block.pinned ? "Unpin" : "Pin").accessibilityLabel("\(block.pinned ? "Unpin" : "Pin") \(block.title)")
                            }
                            if let task, task.state != .done && task.state != .archived {
                                Menu { taskActions(task) } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(task.title)")
                                    .disabled(store.publishingCalendar || store.calendarEditSending)
                            }
                        }.buttonStyle(.plain).font(Theme.body(10, weight: .semibold)).padding(.top, 5)
                    }
                }
            }.foregroundStyle(block.kind == .transition ? Theme.secondary : Theme.text).padding(.vertical, block.kind == .transition ? 12 : 14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).background(block.state == .running ? Theme.goldFill.opacity(0.5) : (hovered && actionable ? Theme.surface : .clear), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }.contextMenu {
            if let task, task.state != .done && task.state != .archived { taskActions(task) }
            else if actionable { Button("Start") { store.start(block) }; Button("Complete") { store.complete(block) }; Button(block.pinned ? "Unpin" : "Pin") { store.pin(block) } }
        }
        .sheet(isPresented: $showPause) { PauseView(block: block) }
        .accessibilityElement(children: .contain)
        .help("\(store.time(block.start))–\(store.time(block.end)) · \(block.minutes) min")
    }
    private var task: PlannerTask? { store.tasks.first { $0.id == block.taskID } }
    private func markCompleted(_ task: PlannerTask) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { _ = store.completeTask(task) }
    }
    @ViewBuilder private func taskActions(_ task: PlannerTask) -> some View {
        Button("Mark completed", systemImage: "checkmark.circle") { markCompleted(task) }
        if actionable && (task.remainingMinutes ?? 0) > block.minutes { Button("Complete this block", systemImage: "checkmark") { store.complete(block) } }
        Button("Move to backlog", systemImage: "arrow.uturn.backward") { _ = store.returnToBacklog(task) }
        Divider()
        Button("Open task", systemImage: "square.and.pencil") { store.editingTask = task }
    }
    private var actionable: Bool { (block.kind == .focus || block.kind == .routine) && (block.state == .planned || block.state == .running) }
    private var color: Color { block.kind == .meeting ? Theme.secondary : (block.kind == .routine ? Theme.green : Theme.gold) }
    private var symbol: String {
        if block.state == .completed { return "checkmark" }
        switch block.kind { case .focus: return "circle.dotted"; case .meeting: return "person.2"; case .transition: return "wind"; case .lunch: return "fork.knife"; case .routine: return store.routines.first { $0.id == block.routineID }?.kind.symbol ?? "sparkles" }
    }
}
