import SwiftUI
import RingCore

struct PriorityReviewSheet: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let request: PriorityReviewRequest
    @State private var task: PlannerTask
    @State private var durationText: String
    @FocusState private var durationFocused: Bool
    init(request: PriorityReviewRequest) {
        self.request = request
        _task = State(initialValue: request.task)
        _durationText = State(initialValue: request.task.remainingMinutes.map(String.init) ?? "")
    }
    private var missing: [TaskRequirement] { TaskTriage.missingRequirements(task) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Confirm before moving")
                Text("Finish the task details").font(Theme.display(29))
                if let q = task.quadrant { Tag(title: "Q\(q.rawValue) · \(q.title)") }
                Text("This task stays where it is until you confirm. Add the missing details to move it into the matrix.").font(Theme.body(12)).foregroundStyle(Theme.secondary).lineSpacing(4)
            }.padding(26)
            Form {
                Section("Task") {
                    TextField("Actionable title", text: $task.title, axis: .vertical).lineLimit(1...3)
                    TextField("Project / context", text: $task.context)
                    TaskAreaPicker(tags: $task.tags)
                    TaskTagEditor(tags: $task.tags, knownTags: store.knownTags)
                }
                Section("Duration estimate") {
                    LabeledContent("Remaining effort") {
                        HStack(spacing: 8) {
                            TextField("", text: $durationText, prompt: Text("Required")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90).focused($durationFocused).accessibilityLabel("Required duration in minutes")
                            Text("minutes").foregroundStyle(Theme.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach([15, 30, 60, 90], id: \.self) { minutes in
                            Button {
                                durationText = String(minutes)
                                task.remainingMinutes = minutes
                                task.minimumBlockMinutes = min(task.minimumBlockMinutes, minutes)
                            } label: {
                                Text("\(minutes) min").font(Theme.body(12, weight: .semibold)).foregroundStyle(task.remainingMinutes == minutes ? Theme.background : Theme.text)
                                    .padding(.horizontal, 13).padding(.vertical, 9).background(task.remainingMinutes == minutes ? Theme.gold : Theme.line.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel("Set duration to \(minutes) minutes")
                        }
                    }
                    Toggle("Allow splitting into focus blocks", isOn: $task.allowsSplitting)
                    Stepper("Minimum useful block: \(task.minimumBlockMinutes) min", value: $task.minimumBlockMinutes, in: 5...90, step: 5)
                }
            }.formStyle(.grouped)
            VStack(alignment: .leading, spacing: 14) {
                if !missing.isEmpty {
                    Text("Still needed: \(missing.map(\.label).joined(separator: ", ")).").font(Theme.body(11)).foregroundStyle(Theme.alert).fixedSize(horizontal: false, vertical: true)
                }
                if let error = store.error { Text(error).font(Theme.body(11)).foregroundStyle(Theme.alert) }
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(task.quadrant.map { "Move to Q\($0.rawValue)" } ?? "Confirm priority") {
                        if (request.inboxItem.map { store.commitInboxPriority(task, item: $0) } ?? store.commitPriority(task, expectedRevision: request.originalRevision)) { dismiss() }
                    }.buttonStyle(GoldButton()).disabled(!missing.isEmpty).keyboardShortcut(.defaultAction)
                }
            }.padding(24)
        }.frame(width: 570, height: 650).background(Theme.background).foregroundStyle(Theme.text).font(Theme.body())
        .onChange(of: durationText) { _, value in task.remainingMinutes = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .onAppear { durationFocused = task.remainingMinutes == nil }
    }
}
