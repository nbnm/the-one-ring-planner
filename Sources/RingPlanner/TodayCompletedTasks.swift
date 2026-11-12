import SwiftUI
import RingCore

struct TodayCompletedTasks: View {
    @EnvironmentObject private var store: PlannerStore
    var body: some View {
        if !store.completedDayTasks.isEmpty {
            DividerLine()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(title: "Completed · \(store.completedDayTasks.count)")
                    Spacer()
                    Button("History") { store.page = .history }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.secondary)
                }
                ForEach(store.completedDayTasks) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Button { _ = store.restoreCompletion(entry, destination: .backlog) } label: {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 21)).foregroundStyle(Theme.green).frame(width: 28, height: 28)
                        }.buttonStyle(.plain).help("Mark incomplete · return to backlog with priority kept")
                            .accessibilityLabel("Mark \(entry.taskSnapshot.title) incomplete and return to backlog")
                            .disabled(store.publishingCalendar || store.calendarEditSending)
                        VStack(alignment: .leading, spacing: 5) {
                            Button { store.editingTask = store.tasks.first { $0.id == entry.taskID } } label: {
                                Text(entry.taskSnapshot.title).font(Theme.body(13)).strikethrough().multilineTextAlignment(.leading)
                            }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                            TaskTagsView(tags: entry.taskSnapshot.tags)
                        }
                        Spacer()
                        if let date = entry.completedAt { Text(store.time(date)).font(Theme.body(10)).monospacedDigit().foregroundStyle(Theme.secondary) }
                    }.padding(.vertical, 7)
                }
            }
        }
    }
}
