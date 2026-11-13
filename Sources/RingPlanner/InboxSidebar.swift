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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tray").foregroundStyle(Theme.gold)
                Button("Inbox") { store.page = .inbox }.buttonStyle(.plain).font(Theme.body(14, weight: .semibold))
                Text("\(store.inbox.count + store.sharedInbox.active.count)").font(Theme.body(10, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.line.opacity(0.5), in: Capsule())
                Spacer()
                Button { AppActions.capture() } label: { Image(systemName: "plus").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Open quick capture").accessibilityLabel("Capture an Inbox item")
            }.padding(.horizontal, 22).frame(height: 64)
            DividerLine()
            VStack(alignment: .leading, spacing: 14) {
                InboxCaptureField(store: store)
            }.padding(20)
            DividerLine().padding(.horizontal, 20)
            InboxContents().padding(.horizontal, 20)

        }.background(Theme.surface.opacity(0.46)).accessibilityElement(children: .contain).accessibilityLabel("Inbox sidebar")
    }
}

private struct InboxCaptureField: View {
    @ObservedObject var store: PlannerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryTextEditor(text: $store.inboxDraft, label: "Quick Inbox capture", onFiles: { files in store.taskCapture.addFiles(files); AppActions.capture() }, onImage: { bytes in store.taskCapture.pasteImage(bytes); AppActions.capture() }).frame(height: 70).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10)).overlay(alignment: .topLeading) { if store.inboxDraft.isEmpty { Text("Capture text, links or images…").font(Theme.body(11)).foregroundStyle(Theme.secondary.opacity(0.8)).padding(12).allowsHitTesting(false) } }
            HStack {
                Button { AppActions.capture() } label: { Label(store.taskCapture.files.isEmpty ? "Add images" : "Images · \(store.taskCapture.files.count)", systemImage: "photo.on.rectangle") }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button { store.saveInboxCapture() } label: { Image(systemName: "arrow.right.circle.fill").font(.system(size: 21)).foregroundStyle(Theme.gold) }.buttonStyle(.plain).disabled(store.sharedInbox.saving || store.taskCapture.preparing > 0 || (store.inboxDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.taskCapture.files.isEmpty)).accessibilityLabel("Save item to Inbox")
            }
        }
    }
}

struct InboxTaskRow: View {
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
                Menu("Move") {
                    Button("Library · Note") { store.moveInboxTaskToLibrary(task) }
                    ForEach(Quadrant.allCases) { q in Button("Q\(q.rawValue) · \(q.title)") { store.assignPriority(taskID: task.id, quadrant: q) } }
                }.menuStyle(.borderlessButton).fixedSize().font(Theme.body(11)).foregroundStyle(Theme.gold)
                Spacer(minLength: 6)
                CopyTextIcon(text: task.notes.isEmpty ? task.title : task.title + "\n\n" + task.notes)
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
