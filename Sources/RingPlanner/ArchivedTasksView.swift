import SwiftUI
import RingCore

struct TaskHistoryView: View {
    @EnvironmentObject var store: PlannerStore
    @State private var section = "Completed"
    @State private var range = "All time"
    @State private var search = ""
    @State private var selected: TaskCompletion?
    private let ranges = ["All time", "Today", "Last 7 days", "Last 30 days"]
    private func matches(_ task: PlannerTask) -> Bool {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || (task.title + " " + task.notes + " " + task.context + " " + task.tags.joined(separator: " ")).localizedCaseInsensitiveContains(text)
    }
    private var entries: [TaskCompletion] {
        let days = range == "Today" ? 1 : range == "Last 7 days" ? 7 : range == "Last 30 days" ? 30 : nil
        let start = days.flatMap { store.calendar.date(byAdding: .day, value: 1 - $0, to: store.calendar.startOfDay(for: store.now)) }
        let end = store.calendar.date(byAdding: .day, value: 1, to: store.calendar.startOfDay(for: store.now))!
        return store.completions.filter { entry in
            matches(entry.taskSnapshot) && (start == nil || entry.completedAt.map { $0 >= start! && $0 < end } == true)
        }.sorted { a, b in
            if a.completedAt != b.completedAt { return (a.completedAt ?? .distantPast) > (b.completedAt ?? .distantPast) }
            return a.id < b.id
        }
    }
    private var archived: [PlannerTask] { store.tasks.filter { $0.state == .archived && matches($0) }.sorted { $0.updatedAt > $1.updatedAt } }
    private var groups: [(key: String, items: [TaskCompletion])] {
        let grouped = Dictionary(grouping: entries) { $0.completedAt.map { PlannerDate.key($0, settings: store.settings) } ?? "" }
        return grouped.keys.sorted(by: >).map { (key: $0, items: grouped[$0]!) }
    }
    private func dayHeading(_ date: Date) -> String {
        let format = DateFormatter(); format.calendar = store.calendar; format.timeZone = store.calendar.timeZone; format.dateStyle = .full; format.timeStyle = .none
        return format.string(from: date)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("History").font(Theme.display(30))
                Spacer()
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 27, weight: .light)).foregroundStyle(Theme.gold)
            }
            HStack(spacing: 16) {
                Picker("History section", selection: $section) {
                    Text("Completed · \(store.completions.count)").tag("Completed")
                    Text("Archived · \(store.tasks.filter { $0.state == .archived }.count)").tag("Archived")
                }.pickerStyle(.segmented).frame(maxWidth: 310)
                Spacer(minLength: 0)
                if section == "Completed" { Picker("Completion dates", selection: $range) { ForEach(ranges, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 135) }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search completed work or projects…", text: $search).textFieldStyle(.plain).accessibilityLabel("Search task history")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel("Clear history search") }
            }.padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            DividerLine()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if section == "Completed" {
                        ForEach(groups, id: \.key) { group in
                            SectionLabel(title: group.items.first?.completedAt.map { dayHeading($0) } ?? "Earlier completions · date unavailable")
                            ForEach(group.items) { entry in completedRow(entry) }
                        }
                        if entries.isEmpty { empty("No completed tasks here yet.", detail: search.isEmpty && range == "All time" ? "Mark a task completed in any quadrant. Its title, details and completion date will be kept here." : "Try another search or date filter.") }
                    } else {
                        ForEach(archived) { task in
                            VStack(alignment: .leading, spacing: 10) {
                                Button { store.editingTask = task } label: { Text(task.title).font(Theme.body(14, weight: .semibold)).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                                TaskTagsView(tags: task.tags)
                                HStack {
                                    Text("Last updated \(store.scheduledDate(task.updatedAt, includeYear: true))").font(Theme.body(10)).foregroundStyle(Theme.secondary)
                                    Spacer()
                                    Button("Move to Inbox") { _ = store.changeTask(task, to: .inbox) }.buttonStyle(QuietButton()).accessibilityLabel("Move \(task.title) to Inbox")
                                }
                                DividerLine()
                            }
                        }
                        if archived.isEmpty { empty("No archived tasks.", detail: "Tasks you put aside remain here until you return them to Inbox.") }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            }
            Text(section == "Completed" ? "Restoring to Inbox keeps the original completion. Dates use \(store.settings.timeZone)." : "Archived tasks stay outside automatic planning.").font(Theme.body(10)).foregroundStyle(Theme.secondary)
        }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $selected) { CompletionDetailsView(entry: $0) }
    }
    private func completedRow(_ entry: TaskCompletion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).padding(.top, 3)
                VStack(alignment: .leading, spacing: 7) {
                    Button { selected = entry } label: { Text(entry.taskSnapshot.title).font(Theme.body(14, weight: .semibold)).multilineTextAlignment(.leading) }.buttonStyle(.plain).accessibilityLabel("Completion details for \(entry.taskSnapshot.title)")
                    HStack(spacing: 10) {
                        Text(entry.completedAt.map { "Completed " + store.time($0) } ?? "Completion date was not recorded by the earlier app version").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                        TaskTagsView(tags: entry.taskSnapshot.tags)
                    }
                    if let date = entry.restoredAt { Text("Restored · \(store.scheduledDate(date, includeYear: true))").font(Theme.body(10)).foregroundStyle(Theme.gold) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if store.canRestoreCompletion(entry) {
                    Button("Restore to Inbox") { _ = store.restoreCompletion(entry) }.buttonStyle(QuietButton()).accessibilityLabel("Restore \(entry.taskSnapshot.title) to Inbox")
                }
            }
            DividerLine()
        }
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(Theme.display(25)); Text(detail).font(Theme.body(13)).foregroundStyle(Theme.secondary).frame(maxWidth: 420, alignment: .leading) }.padding(.vertical, 36)
    }
}

private struct CompletionDetailsView: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let entry: TaskCompletion
    private var currentEntry: TaskCompletion { store.completions.first { $0.id == entry.id } ?? entry }
    private var affectedPlans: [DayPlan] {
        store.plans.filter { plan in
            plan.publication?.state == .needsConfirmation && plan.publication?.desired.contains { $0.taskID == entry.taskID && $0.end > store.now } == true
        }.sorted { $0.id < $1.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { SectionLabel(title: "Completed task · saved snapshot"); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(entry.taskSnapshot.title).font(Theme.display(27)).fixedSize(horizontal: false, vertical: true)
            Text(entry.completedAt.map { "Completed " + store.scheduledDate($0, includeYear: true) } ?? "The earlier app version did not record a completion date.").font(Theme.body(13)).foregroundStyle(Theme.green)
            DividerLine()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !entry.taskSnapshot.context.isEmpty { Text(entry.taskSnapshot.context).font(Theme.body(13)).foregroundStyle(Theme.secondary) }
                    TaskTagsView(tags: entry.taskSnapshot.tags)
                    if !entry.taskSnapshot.notes.isEmpty { Text(entry.taskSnapshot.notes).font(Theme.body(13)).textSelection(.enabled) }
                    if !entry.taskSnapshot.resumeNote.isEmpty { SectionLabel(title: "Last resume note"); Text(entry.taskSnapshot.resumeNote).font(Theme.body(13)).textSelection(.enabled) }
                    if let q = entry.taskSnapshot.quadrant { Text("Q\(q.rawValue) · \(q.title)").font(Theme.body(11)).foregroundStyle(Theme.secondary) }
                    if let date = currentEntry.restoredAt { Text("Restored to Inbox · \(store.scheduledDate(date, includeYear: true))\nThis completion remains in History.").font(Theme.body(12)).foregroundStyle(Theme.gold) }
                    if !affectedPlans.isEmpty {
                        DividerLine()
                        Text("Future Google Calendar bookings remain until you confirm the revised day plans.").font(Theme.body(12)).foregroundStyle(Theme.alert)
                        ForEach(affectedPlans) { plan in Button("Review day plan · \(plan.id)") { store.openHistoryPlan(plan); dismiss() }.buttonStyle(QuietButton()) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Restoring preserves this record and returns the task to Inbox for review.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                Spacer()
                if store.canRestoreCompletion(currentEntry) { Button("Restore to Inbox") { if store.restoreCompletion(currentEntry) { dismiss() } }.buttonStyle(GoldButton()) }
            }
        }.padding(28).frame(width: 610, height: 550).background(Theme.background).foregroundStyle(Theme.text)
    }
}
