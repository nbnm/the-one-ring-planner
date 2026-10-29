import SwiftUI
import RingCore

struct MatrixView: View {
    @EnvironmentObject var store: PlannerStore
    @State private var tagFilter = TaskTagFilter.all
    @State private var grouped = false
    @State private var search = ""
    private var filteredTasks: [PlannerTask] {
        store.activeTasks.filter { task in
            tagFilter.matches(task) && (search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                (task.title + " " + task.context + " " + task.tags.joined(separator: " ")).localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }
    private func tasks(in quadrant: Quadrant) -> [PlannerTask] { filteredTasks.filter { $0.quadrant == quadrant } }
    var body: some View {
        Group {
            if let quadrant = store.expandedQuadrant { expanded(quadrant) }
            else { overview }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Priority matrix").font(Theme.display(29))
                }
                Spacer(minLength: 0)
                Button(store.buildingPlan ? "Building…" : "Build a draft") { store.generate(); store.page = .today }
                    .buttonStyle(GoldButton()).fixedSize().disabled(store.buildingPlan)
            }
            controls
            GeometryReader { geometry in
                VStack(spacing: 12) {
                    ForEach(0..<2) { row in
                        HStack(spacing: 12) {
                            ForEach(Array(Quadrant.allCases.dropFirst(row * 2).prefix(2))) { quadrant in
                                QuadrantPanel(quadrant: quadrant, tasks: tasks(in: quadrant), grouped: grouped,
                                    filtered: tagFilter != .all || !search.isEmpty) { store.expandQuadrant(quadrant) }
                            }
                        }.frame(height: max(0, (geometry.size.height - 12) / 2))
                    }
                }
            }
            HStack {
                Spacer()
                Button { store.page = .history } label: { Label("History · \(store.completions.count) completed", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gold)
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }
    private var controls: some View {
        HStack(spacing: 18) {
            TaskTagControls(tags: store.knownTags, filter: $tagFilter, grouped: $grouped).frame(width: 220)
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search tasks or projects…", text: $search).textFieldStyle(.plain).accessibilityLabel("Search matrix tasks")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear matrix search")
                }
            }.font(Theme.body(11)).padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                .frame(maxWidth: store.expandedQuadrant == nil ? 280 : 420)
        }
    }
    private func expanded(_ quadrant: Quadrant) -> some View {
        let visible = tasks(in: quadrant)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { store.closeExpandedQuadrant() } label: { Label("Back to matrix", systemImage: "arrow.left") }
                    .buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                    .help("Return to all quadrants · Escape")
                Spacer()
                Text("\(visible.count) \(visible.count == 1 ? "task" : "tasks") · \(store.duration(visible.reduce(0) { $0 + ($1.remainingMinutes ?? 0) }))")
                    .font(Theme.body(12)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .center, spacing: 16) {
                Text("Q\(quadrant.rawValue)").font(Theme.display(36)).foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 4) {
                    Text(quadrant.title).font(Theme.display(30))
                    Text(quadrant.subtitle).font(Theme.body(12)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 24)
                Picker("Open quadrant", selection: Binding(get: { store.expandedQuadrant ?? quadrant }, set: { value in
                    if store.expandedQuadrant != value { store.expandedQuadrant = value }
                })) {
                    ForEach(Quadrant.allCases) { q in Text("Q\(q.rawValue) · \(q.title)").tag(q) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 600).accessibilityLabel("Open quadrant")
            }
            controls
            DividerLine()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(TaskTagGroup.make(visible, grouped: grouped)) { group in
                        TagGroupHeading(group: group)
                        ForEach(group.tasks) { task in MatrixTaskRow(task: task, expanded: true); DividerLine() }
                    }
                    if visible.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(search.isEmpty && tagFilter == .all ? "A little room in Q\(quadrant.rawValue)." : "No matching tasks.").font(Theme.display(24))
                            Text(search.isEmpty && tagFilter == .all ? "Return to the matrix to move tasks here from Inbox or another quadrant." : "Try another search or project filter.")
                                .font(Theme.body(13)).foregroundStyle(Theme.secondary)
                        }.padding(.vertical, 36)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Completed task history") { store.page = .history }.buttonStyle(.plain).foregroundStyle(Theme.gold)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityLabel("Q\(quadrant.rawValue) \(quadrant.title), full screen")
    }
}

private struct QuadrantPanel: View {
    @EnvironmentObject var store: PlannerStore
    let quadrant: Quadrant
    let tasks: [PlannerTask]
    let grouped: Bool
    let filtered: Bool
    let expand: () -> Void
    private var targeted: Bool { store.taskDrag.map { store.priorityDropTarget(at: $0.location) == quadrant } ?? false }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("Q\(quadrant.rawValue)").font(Theme.display(21)).foregroundStyle(Theme.gold)
                Text(quadrant.title).font(Theme.body(12, weight: .semibold)).lineLimit(1)
                Text("\(tasks.count)").font(Theme.body(10, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.line.opacity(0.4), in: Capsule())
                    .accessibilityLabel("\(tasks.count) \(tasks.count == 1 ? "task" : "tasks") in Q\(quadrant.rawValue)")
                Spacer(minLength: 0)
                if targeted { Image(systemName: "arrow.down.to.line").foregroundStyle(Theme.gold) }
                Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(Theme.gold)
                    .help("Open Q\(quadrant.rawValue) in full screen")
                    .accessibilityLabel("Expand Q\(quadrant.rawValue) · \(quadrant.title)")
            }
            Text(quadrant.subtitle).font(Theme.body(10)).foregroundStyle(Theme.secondary)
            DividerLine()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(TaskTagGroup.make(tasks, grouped: grouped)) { group in
                        TagGroupHeading(group: group)
                        ForEach(group.tasks) { task in MatrixTaskRow(task: task); DividerLine() }
                    }
                    if tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(targeted ? "Drop to move here" : (filtered ? "No matching tasks" : "Drop a task here")).font(Theme.body(12, weight: .semibold))
                        }.foregroundStyle(Theme.secondary).padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 0, maxHeight: .infinity)
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(targeted ? Theme.goldFill : Theme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(targeted ? Theme.gold : Theme.line, lineWidth: targeted ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PriorityDropRegionsKey.self,
                    value: [quadrant: geometry.frame(in: .named(PlannerDragSpace.workspace))])
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: targeted)
        .accessibilityElement(children: .contain).accessibilityLabel("Q\(quadrant.rawValue) \(quadrant.title), drop target")
    }
}

private struct MatrixTaskRow: View {
    @EnvironmentObject var store: PlannerStore
    let task: PlannerTask
    var expanded = false
    private var state: String? { task.state == .waiting ? "Waiting" : task.state == .inProgress ? "In progress" : nil }
    var body: some View {
        Group {
            if expanded { expandedRow }
            else { compactRow }
        }.padding(.vertical, expanded ? 13 : 8).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
    }
    private var outcome: some View {
        Button { store.toggleOutcome(task) } label: {
            Image(systemName: store.plan?.outcomeIDs.contains(task.id) == true ? "star.fill" : "star").foregroundStyle(Theme.gold).frame(width: 18, height: 24)
        }.buttonStyle(.plain).help("Toggle selected outcome").accessibilityLabel("Toggle outcome for \(task.title)")
    }
    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                complete
                outcome
                TaskDragTitle(taskID: task.id, title: task.title, lineLimit: 2) { store.editingTask = task }.help(task.title)
            }
            HStack(spacing: 6) {
                Text("\(task.remainingMinutes ?? 0)m").monospacedDigit().fixedSize()
                if let state { Text(state).foregroundStyle(Theme.gold).fixedSize() }
                if let tag = task.tags.first {
                    Text("#\(tag)\(task.tags.count > 1 ? " +\(task.tags.count - 1)" : "")").lineLimit(1).foregroundStyle(Theme.gold)
                        .help(task.tags.joined(separator: ", ")).accessibilityLabel("Tags: \(task.tags.joined(separator: ", "))")
                } else if !task.context.isEmpty { Text(task.context).lineLimit(1).help(task.context) }
                Spacer(minLength: 0)
                PriorityMenu(task: task, compact: true)
                if task.quadrant == .schedule {
                    Button { store.offerTimeSlot(for: task) } label: { Image(systemName: "calendar.badge.plus").frame(width: 22, height: 20) }
                        .buttonStyle(.plain).foregroundStyle(Theme.gold).help("Find calendar time")
                        .accessibilityLabel("Find calendar time for \(task.title)")
                }
            }.font(Theme.body(10)).foregroundStyle(Theme.secondary).padding(.leading, 24)
            if task.quadrant == .schedule { scheduleLabel.padding(.leading, 24) }
        }
    }
    private var expandedRow: some View {
        HStack(alignment: .center, spacing: 20) {
            complete
            outcome
            VStack(alignment: .leading, spacing: 6) {
                Button { store.editingTask = task } label: { Text(task.title).font(Theme.body(14, weight: .semibold)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).help("Edit task").accessibilityLabel("Edit \(task.title)")
                HStack(spacing: 12) {
                    if !task.context.isEmpty { Text(task.context).font(Theme.body(11)).foregroundStyle(Theme.secondary) }
                    TaskTagsView(tags: task.tags)
                }
                if task.quadrant == .schedule { scheduleLabel }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(task.remainingMinutes ?? 0) min").font(Theme.body(12, weight: .semibold)).monospacedDigit()
                if let state { Text(state).font(Theme.body(10)).foregroundStyle(Theme.gold) }
            }.frame(width: 80, alignment: .trailing)
            PriorityMenu(task: task).frame(width: 150, alignment: .trailing)
            if task.quadrant == .schedule {
                Button("Find calendar time") { store.offerTimeSlot(for: task) }.buttonStyle(QuietButton())
            }
            Button { store.editingTask = task } label: { Image(systemName: "square.and.pencil").frame(width: 26, height: 28) }
                .buttonStyle(.plain).foregroundStyle(Theme.gold).help("Edit task").accessibilityLabel("Open details for \(task.title)")
        }
    }
    private var complete: some View {
        Button { _ = store.completeTask(task) } label: {
            Image(systemName: "circle").font(.system(size: expanded ? 19 : 15)).frame(width: expanded ? 28 : 20, height: 24)
        }.buttonStyle(.plain).foregroundStyle(Theme.green)
            .help("Mark completed now, regardless of its planned date. Kept in History.")
            .accessibilityLabel("Mark \(task.title) completed")
    }
    @ViewBuilder private var scheduleLabel: some View {
        let entries = store.scheduledEntries(for: task)
        if let first = entries.first(where: { $0.status == .calendar }) ?? entries.first(where: { $0.status == .pending }) ?? entries.first {
            let text = "\(first.status.rawValue) · \(store.scheduledDate(first.start))\(entries.count > 1 ? " · +\(entries.count - 1)" : "")"
            Button { store.selectedDay = first.start; store.page = .today } label: {
                Label(text, systemImage: first.status == .calendar ? "calendar.badge.checkmark" : "calendar")
                    .font(Theme.body(expanded ? 11 : 10)).lineLimit(1)
            }.buttonStyle(.plain).foregroundStyle(first.status == .calendar ? Theme.green : Theme.secondary)
                .help(entries.map { "\($0.status.rawValue) · \(store.scheduledDate($0.start, includeYear: true))–\(store.time($0.end))" }.joined(separator: "\n") + "\n" + store.settings.timeZone)
                .accessibilityLabel("\(task.title): \(text). Open scheduled day")
        } else {
            EmptyView()
        }
    }
}
