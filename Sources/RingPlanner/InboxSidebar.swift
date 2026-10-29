import SwiftUI
import RingCore

struct PriorityMenu: View {
    @EnvironmentObject var store: PlannerStore
    let task: PlannerTask
    var compact = false
    var body: some View {
        Menu {
            ForEach(Quadrant.allCases) { q in
                Button {
                    store.assignPriority(taskID: task.id, quadrant: q)
                } label: {
                    if task.quadrant == q { Label("Q\(q.rawValue) · \(q.title)", systemImage: "checkmark") }
                    else { Text("Q\(q.rawValue) · \(q.title)") }
                }.help(q.subtitle)
            }
        } label: {
            Text(task.quadrant.map { compact ? "Q\($0.rawValue)" : "Q\($0.rawValue) · \($0.title)" } ?? "Assign priority")
                .font(Theme.body(11, weight: .semibold)).foregroundStyle(Theme.gold)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Priority for \(task.title)")
        .accessibilityValue(task.quadrant.map { "Q\($0.rawValue) · \($0.title)" } ?? "Unassigned")
        .help("Change importance and urgency by choosing a quadrant")
    }
}

struct InboxSidebar: View {
    @EnvironmentObject var store: PlannerStore
    @State private var tagFilter = TaskTagFilter.all
    @State private var grouped = false
    private var groups: [TaskTagGroup] { TaskTagGroup.make(store.inbox, grouped: grouped, filter: tagFilter) }
    private var visibleCount: Int { groups.reduce(0) { $0 + $1.tasks.count } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tray").foregroundStyle(Theme.gold)
                Text("Inbox").font(Theme.body(14, weight: .semibold))
                Text("\(store.inbox.count)").font(Theme.body(10, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.line.opacity(0.5), in: Capsule())
                Spacer()
                Button { AppActions.capture() } label: { Image(systemName: "plus").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Open quick capture").accessibilityLabel("Capture a task in Inbox")
            }.padding(.horizontal, 22).frame(height: 64)
            DividerLine()
            VStack(alignment: .leading, spacing: 14) {
                InboxCaptureField(store: store, speech: store.inboxSpeech)
            }.padding(20)
            if !store.inbox.isEmpty {
                TaskTagControls(tags: store.knownTags, filter: $tagFilter, grouped: $grouped).padding(.horizontal, 20).padding(.bottom, 14)
            }
            DividerLine().padding(.horizontal, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.inbox.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "tray").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(Theme.gold).padding(.bottom, 5)
                            Text("Nothing waiting.").font(Theme.display(22))
                        }.padding(.vertical, 28).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !store.inbox.isEmpty && visibleCount == 0 {
                        Text("No tasks with this tag.").font(Theme.body(12)).foregroundStyle(Theme.secondary).padding(.top, 24)
                        Button("Show all tasks") { tagFilter = .all }.buttonStyle(.plain).foregroundStyle(Theme.gold).font(Theme.body(11)).padding(.top, 8)
                    }
                    ForEach(groups) { group in
                        TagGroupHeading(group: group)
                        ForEach(group.tasks) { task in
                            InboxTaskRow(task: task)
                            DividerLine()
                        }
                    }
                }.padding(.horizontal, 20)
            }
        }.background(Theme.sidebar.opacity(0.46)).accessibilityElement(children: .contain).accessibilityLabel("Inbox sidebar")
    }
}

private struct InboxCaptureField: View {
    @ObservedObject var store: PlannerStore
    @ObservedObject var speech: SpeechCapture
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TextField("Capture a task…", text: $store.inboxDraft).textFieldStyle(.plain).font(Theme.body(12))
                    .focused($focused).disabled(speech.isBusy)
                    .onSubmit { store.saveInboxCapture() }.accessibilityLabel("Quick inbox task")
                Button { AppActions.recordInbox() } label: {
                    Image(systemName: speech.isBusy ? "stop.circle.fill" : "mic")
                        .font(.system(size: 17)).foregroundStyle(speech.isBusy ? Theme.alert : Theme.gold)
                        .frame(width: 22, height: 24)
                }.buttonStyle(.plain)
                    .accessibilityLabel(speech.isBusy ? "Stop Inbox recording" : "Start Inbox recording")
                    .help(speech.isBusy ? "Stop recording · Control Option R" : "Record to Inbox · Control Option R")
                Button { store.saveInboxCapture() } label: {
                    Image(systemName: "arrow.right.circle.fill").font(.system(size: 19)).foregroundStyle(Theme.gold)
                }.buttonStyle(.plain)
                    .disabled(speech.isBusy || store.inboxDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Clean up and review captured tasks").help("Clean up and review task drafts")
            }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(speech.isBusy ? Theme.gold : Theme.line))
            HStack(spacing: 6) {
                if speech.isStarting {
                    ProgressView().controlSize(.mini)
                    Text(speech.status)
                } else if speech.isFinishing {
                    ProgressView().controlSize(.mini)
                    Text("Finishing transcript…")
                } else if speech.recording {
                    Circle().fill(Theme.alert).frame(width: 5, height: 5)
                    Text("Recording · up to 60 seconds")
                }
            }.font(Theme.body(10)).foregroundStyle(speech.isBusy ? Theme.alert : Theme.secondary)
            if let message = speech.message {
                Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert).lineSpacing(3)
            }
        }
        .onChange(of: speech.isBusy) { _, busy in focused = !busy }
    }
}

private struct InboxTaskRow: View {
    @EnvironmentObject var store: PlannerStore
    private let original: PlannerTask
    init(task: PlannerTask) { original = task }
    private var task: PlannerTask { store.tasks.first { $0.id == original.id } ?? original }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaskDragTitle(taskID: task.id, title: task.title, fontSize: 13, lineSpacing: 3) { store.editingTask = task }
            HStack(spacing: 6) {
                if let minutes = task.remainingMinutes, minutes >= 5 { Text("\(minutes) min").foregroundStyle(Theme.secondary) }
                else { Label("Needs duration", systemImage: "clock").foregroundStyle(Theme.secondary) }
                if !task.context.isEmpty { Text("· \(task.context)").foregroundStyle(Theme.secondary).lineLimit(1) }
            }.font(Theme.body(10))
            TaskTagsView(tags: task.tags)
            HStack {
                PriorityMenu(task: task)
                Spacer(minLength: 6)
                Button { store.editingTask = task } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Review task").accessibilityLabel("Review \(task.title)")
                Menu {
                    Button("Refine with AI…") { store.refineInboxTask(task) }
                    Divider()
                    Button("Archive task") { store.archive(task) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Theme.secondary).accessibilityLabel("More actions for \(task.title)")
            }
        }
        .padding(.vertical, 14).contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .help("Drag to a priority quadrant, or use Assign priority")
    }
}

struct PlanBalanceStrip: View {
    @EnvironmentObject var store: PlannerStore
    let plan: DayPlan
    @State private var showingDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                metric("Planned", value: store.duration(plan.plannedMinutes))
                metric("Free", value: store.duration(plan.freeMinutes))
                metric("Reserve", value: store.duration(plan.reserveMinutes))
                Spacer(minLength: 0)
                Button { showingDetails.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel("Show daily capacity details")
                    .popover(isPresented: $showingDetails) { DayInspector().frame(width: 280, height: 650).environmentObject(store) }
            }
            CalendarPublicationPanel(plan: plan, compact: true)
            DividerLine()
        }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(Theme.display(23)); Text(title).font(Theme.body(10)).foregroundStyle(Theme.secondary) }
    }
}
