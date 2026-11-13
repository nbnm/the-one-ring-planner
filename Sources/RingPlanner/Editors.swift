import SwiftUI
import AppKit
import RingCore

struct TaskEditor: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) var dismiss
    @State var task: PlannerTask
    @State private var hasDeadline: Bool
    @State private var deleting = false
    init(task: PlannerTask) { _task = State(initialValue: task); _hasDeadline = State(initialValue: task.deadline != nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(task.state == .inbox ? "Review task" : "Task details").font(Theme.display(28)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction) }.padding(26)
            Form {
                Section("The task") {
                    TextField("Actionable title", text: $task.title, axis: .vertical).lineLimit(2...4)
                    ReferenceLinksView(text: task.notes)
                    TextField("Project / context", text: $task.context, prompt: Text("e.g. T1A · Presales"))
                    TextField("Supporting details", text: $task.notes, axis: .vertical).lineLimit(2...5)
                    TaskAreaPicker(tags: $task.tags)
                    TaskTagEditor(tags: $task.tags, knownTags: store.knownTags)
                    if !task.attachments.isEmpty { TaskImageAttachments(attachments: task.attachments, repository: store.repository) }
                }
                Section("Separate decisions") {
                    Picker("Importance", selection: Binding(get: { task.importance.map { $0 ? 1 : 2 } ?? 0 }, set: { task.importance = $0 == 0 ? nil : $0 == 1 })) { Text("Choose…").tag(0); Text("Important").tag(1); Text("Not important").tag(2) }
                    Picker("Urgency", selection: Binding(get: { task.urgency.map { $0 ? 1 : 2 } ?? 0 }, set: { task.urgency = $0 == 0 ? nil : $0 == 1 })) { Text("Choose…").tag(0); Text("Urgent").tag(1); Text("Not urgent").tag(2) }
                    if let q = task.quadrant { Text("Q\(q.rawValue) · \(q.title)").foregroundStyle(Theme.gold) }
                }
                Section("Effort estimate") {
                    HStack { ForEach([15, 30, 60, 90], id: \.self) { n in Button("\(n) min") { task.remainingMinutes = n; task.minimumBlockMinutes = min(25, n) }.buttonStyle(QuietButton()).tint(task.remainingMinutes == n ? Theme.gold : Theme.secondary) } }
                    Stepper("Remaining: \(task.remainingMinutes ?? 0) minutes", value: Binding(get: { task.remainingMinutes ?? 30 }, set: { task.remainingMinutes = $0 }), in: 5...600, step: 5)
                    Toggle("Allow splitting into focus blocks", isOn: $task.allowsSplitting)
                    Stepper("Minimum useful block: \(task.minimumBlockMinutes) min", value: $task.minimumBlockMinutes, in: 5...90, step: 5)
                }
                Section("Timing & context") {
                    Toggle("Has a deadline", isOn: $hasDeadline)
                    if hasDeadline { DatePicker("Deadline", selection: Binding(get: { task.deadline ?? Date() }, set: { task.deadline = $0 })).environment(\.timeZone, store.calendar.timeZone) }
                    TextField("Resume note / next action", text: $task.resumeNote, axis: .vertical).lineLimit(2...3)
                    Picker("State", selection: $task.state) { Text("Inbox").tag(TaskState.inbox); Text("Ready").tag(TaskState.ready); Text("Waiting").tag(TaskState.waiting); Text("Done").tag(TaskState.done); Text("Archived").tag(TaskState.archived); if task.state == .inProgress { Text("In progress").tag(TaskState.inProgress) } }
                    if !task.dependencies.isEmpty { Text("Prerequisites: \(task.dependencies.joined(separator: ", "))").font(Theme.body(11)); Button("Clear prerequisites") { task.dependencies = [] } }
                }
            }.formStyle(.grouped)
            HStack {
                Menu("Task actions") {
                    Button("Mark completed", systemImage: "checkmark.circle") { change(.complete) }.disabled(task.state == .done || task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Move to Inbox", systemImage: "tray") { change(.inbox) }.disabled(task.state == .inbox || task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Archive task", systemImage: "archivebox") { change(.archive) }.disabled(task.state == .archived || task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Divider()
                    Button("Delete task…", systemImage: "trash", role: .destructive) { deleting = true }
                }.fixedSize().accessibilityLabel("Task actions")
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 14)
            HStack {
                Text(valid ? (task.quadrant?.subtitle ?? "Kept outside automatic planning") : "Choose importance, urgency and an effort estimate.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButton())
                Button("Save task") {
                    if store.update(preparedTask) { dismiss() }
                }.buttonStyle(GoldButton()).disabled(!valid).keyboardShortcut(.defaultAction)
            }.padding(22)
        }.frame(width: 640, height: 730).background(Theme.background).foregroundStyle(Theme.text).font(Theme.body())
        .alert("Delete this task?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Delete task", role: .destructive) { change(.delete) }
        } message: {
            Text("\(task.title)\n\nDeletes the task and its entries from saved plans. Original captures and Git history are kept. Tasks depending on it stay blocked until their prerequisites are reviewed.")
        }
    }
    private var preparedTask: PlannerTask {
        var edited = task
        edited.title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.deadline = hasDeadline ? edited.deadline ?? Date() : nil
        return edited
    }
    private func change(_ disposition: TaskDisposition) {
        if store.changeTask(preparedTask, to: disposition) { dismiss() }
    }
    private var valid: Bool { !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (task.state == .inbox || task.state == .waiting || task.state == .done || task.state == .archived || (task.quadrant != nil && (task.remainingMinutes ?? 0) > 0 && task.minimumBlockMinutes <= (task.remainingMinutes ?? 0))) }
}

struct PauseView: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) var dismiss
    let block: PlanBlock
    @State private var note = ""
    @State private var remaining = 25
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionLabel(title: "Leave yourself a way back")
            Text("Continue later").font(Theme.display(30))
            Text(block.title).font(Theme.body(14, weight: .semibold))
            TextField("Where did you stop? What’s next?", text: $note, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
            Stepper("Remaining effort: \(remaining) minutes", value: $remaining, in: 5...600, step: 5)
            HStack { Button("Cancel") { dismiss() }.buttonStyle(QuietButton()); Spacer(); Button("Save & pause") { store.pause(block, remaining: remaining, note: note); if store.error == nil { dismiss() } }.buttonStyle(GoldButton()) }
        }.padding(30).frame(width: 480).background(Theme.background).foregroundStyle(Theme.text).onAppear { remaining = store.tasks.first { $0.id == block.taskID }?.remainingMinutes ?? block.minutes }
    }
}

struct MinutePicker: View {
    let title: String
    @Binding var minute: Int
    var includesEndOfDay = false
    var body: some View {
        Picker(title, selection: $minute) { ForEach(Array(stride(from: 0, through: includesEndOfDay ? 1440 : 1425, by: 15)), id: \.self) { n in Text(String(format: "%02d:%02d", n / 60, n % 60)).tag(n) } }
    }
}
struct ReviewView: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Daily review").font(Theme.display(30))
                DividerLine()
                reviewStep("01", title: "In progress", detail: "\(store.tasks.filter { $0.state == .inProgress }.count) tasks")
                ForEach(store.tasks.filter { $0.state != .archived && $0.state != .done && ($0.state == .inProgress || !$0.resumeNote.isEmpty) }) { t in
                    Button { store.editingTask = t } label: { HStack { Text(t.title); Spacer(); Text("Review →").foregroundStyle(Theme.gold) } }.buttonStyle(.plain).font(Theme.body(13))
                }
                DividerLine()
                reviewStep("02", title: "Inbox", detail: "\(store.inbox.count + store.sharedInbox.active.count) items to review")
                Button("Open Inbox →") { store.page = .inbox }.buttonStyle(.plain).foregroundStyle(Theme.gold)
                DividerLine()
                reviewStep("03", title: "Next workday", detail: store.dayTitle(store.nextPlanningDay))
                HStack(spacing: 14) {
                    Button("Prepare next workday’s draft") { store.chooseTasks(for: store.nextPlanningDay) }.buttonStyle(GoldButton())
                    Button("Choose outcomes") { store.selectedDay = store.nextPlanningDay; store.page = .matrix }.buttonStyle(QuietButton())
                }
            }.padding(36).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func reviewStep(_ n: String, title: String, detail: String) -> some View { HStack(alignment: .top, spacing: 20) { Text(n).font(Theme.display(25)).foregroundStyle(Theme.gold); VStack(alignment: .leading, spacing: 7) { Text(title).font(Theme.body(15, weight: .semibold)); Text(detail).font(Theme.body(12)).foregroundStyle(Theme.secondary) } } }
}

struct PreferencesView: View {
    @EnvironmentObject var store: PlannerStore
    @State private var settings = PlanningSettings()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Settings").font(Theme.display(30)); Spacer(); Button("Save preferences") { store.saveSettings(settings) }.buttonStyle(GoldButton()) }
            Form {
                Section("Workday") {
                    MinutePicker(title: "Start work", minute: $settings.workStart)
                    MinutePicker(title: "Finish work", minute: $settings.workEnd)
                    MinutePicker(title: "Lunch starts", minute: $settings.lunchStart)
                    Stepper("Lunch: \(settings.lunchMinutes) minutes", value: $settings.lunchMinutes, in: 0...120, step: 15)
                    TextField("IANA time zone", text: $settings.timeZone)
                    DetailNote("Time zone", "Work and routine windows use this time zone. Drafts never extend the working day.")
                }
                Section("Personal time") {
                    MinutePicker(title: "Weekdays from", minute: personalMinute(\.weekdayStart))
                    MinutePicker(title: "Weekdays until", minute: personalMinute(\.weekdayEnd))
                    MinutePicker(title: "Weekends from", minute: personalMinute(\.weekendStart))
                    MinutePicker(title: "Weekends until", minute: personalMinute(\.weekendEnd))
                    DetailNote("Personal planning", "Personal tags use these windows, including weekends. Calendar commitments still block time. Change a task’s Work / Personal tag to correct AI categorization.")
                }
                Section("Planning") {
                    Stepper("Interruption reserve: \(settings.reservePercent)%", value: $settings.reservePercent, in: 0...50, step: 5)
                    Stepper("Focus block: \(settings.focusMinutes) minutes", value: $settings.focusMinutes, in: 25...90, step: 5)
                    Stepper("Default minimum block: \(settings.minimumFocusMinutes) minutes", value: $settings.minimumFocusMinutes, in: 5...50, step: 5)
                    DetailNote("Transition rules", "Transitions: related tasks 5m · project changes 10m · meeting preparation 5m · recovery 10m. Shared gaps are counted once.")
                }
                Section("Navigation") { Toggle("Group Routines, Daily review and History under More", isOn: Binding(get: { store.compactNavigation }, set: { store.compactNavigation = $0 })) }
                if store.publicationDefaults.string(forKey: "workspace.restoredRoot") != nil {
                    Section("Workspace selection") {
                        Button("Return to the original workspace on next launch") {
                            guard !store.library.recordingIsActive(), !store.library.saving else { store.error = "Finish recording and saves before changing workspaces."; return }
                            store.publicationDefaults.removeObject(forKey: "workspace.restoredRoot"); store.publicationDefaults.removeObject(forKey: "workspace.restoredMeetings"); store.publicationDefaults.set(true, forKey: "workspace.restoreNeedsReview")
                            store.showNotice("Original workspace selected · quit and reopen to switch.")
                        }
                    }
                }
                if store.publicationDefaults.bool(forKey: "workspace.restoreNeedsReview") {
                    Section("Restored calendar data") {
                        Text("Review the restored plans and pending calendar changes before allowing writes. Calendar sync starts disabled for this workspace.")
                        Button("Allow saved calendar changes after review") { store.publicationDefaults.set(false, forKey: "workspace.restoreNeedsReview"); store.calendarConnection.resumeAfterRestoreReview(); store.objectWillChange.send() }
                    }
                }
                TelegramSettingsSection(telegram: store.telegram)
                LibrarySettingsSections(library: store.library)
                Section("Completion") {
                    Toggle("Play a soft chime", isOn: Binding(get: { store.completionSoundEnabled }, set: { store.completionSoundEnabled = $0 }))
                }
                Section("Capture") {
                    LabeledContent("Quick capture shortcut", value: "Control + Option + Space")

                }
                LiteLLMSettingsSection(settings: store.captureAI)
                EventAlertSettingsSection(alerts: store.eventAlerts)
                CalendarSettingsSection(connection: store.calendarConnection)
                Section("Workspace & connections") {
                    LabeledContent("Task storage", value: "This Mac")
                    if let repo = store.repository {
                        DisclosureGroup("Data location") {
                            Text(repo.root.path).font(Theme.body(10)).textSelection(.enabled)
                            Button("Open data folder") { NSWorkspace.shared.open(repo.root) }
                        }
                    }
                    DetailNote("Storage details", "Git retains previous versions of task text after deletion. Confirming a plan adds its scheduled tasks and routines to your chosen Google calendar; drafts stay local.")
                }
            }.formStyle(.grouped)
        }.padding(32).onAppear { settings = store.settings }
    }
    private func personalMinute(_ key: WritableKeyPath<PersonalAvailability, Int>) -> Binding<Int> {
        Binding(get: { (settings.personalAvailability ?? PersonalAvailability())[keyPath: key] }, set: { value in var p = settings.personalAvailability ?? PersonalAvailability(); p[keyPath: key] = value; settings.personalAvailability = p })
    }
}
