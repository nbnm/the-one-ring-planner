import SwiftUI
import RingCore

private enum RoutineRepeat: String, CaseIterable {
    case daily = "Every day", weekdays = "Weekdays", weekends = "Weekends", custom = "Selected days…"
    init(days: [RoutineWeekday]) {
        switch Set(days) {
        case Set(RoutineWeekday.allCases): self = .daily
        case Set(RoutineWeekday.workdays): self = .weekdays
        case Set(RoutineWeekday.weekend): self = .weekends
        default: self = .custom
        }
    }
    var days: [RoutineWeekday]? {
        switch self { case .daily: return RoutineWeekday.allCases; case .weekdays: return RoutineWeekday.workdays; case .weekends: return RoutineWeekday.weekend; case .custom: return nil }
    }
}

struct RoutineEditor: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var routine: Routine
    @State private var repeatRule: RoutineRepeat
    let isNew: Bool
    init(routine: Routine, isNew: Bool = false) {
        _routine = State(initialValue: routine)
        _repeatRule = State(initialValue: RoutineRepeat(days: routine.weekdays))
        self.isNew = isNew
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(title: isNew ? "Make a little room" : "Routine preferences")
                Text(isNew ? "Create a routine." : "Make it work for you.").font(Theme.display(28))
            }.padding(26)
            Form {
                Section("The routine") {
                    TextField("Name", text: $routine.title, prompt: Text("e.g. Read a chapter"))
                        .accessibilityLabel("Routine name")
                    Toggle("Include in future drafts", isOn: $routine.enabled)
                    Picker("Icon & celebration", selection: $routine.kind) {
                        ForEach(RoutineKind.allCases, id: \.self) { kind in Label(kind.title, systemImage: kind.symbol).tag(kind) }
                    }
                }
                Section("Repeat") {
                    Picker("Repeats", selection: $repeatRule) {
                        ForEach(RoutineRepeat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.onChange(of: repeatRule) { _, value in
                        if let days = value.days { routine.weekdays = days }
                    }
                    if repeatRule == .custom {
                        HStack(spacing: 8) {
                            ForEach(RoutineWeekday.allCases) { day in
                                Toggle(day.shortTitle, isOn: Binding(get: { routine.weekdays.contains(day) }, set: { included in
                                    routine.weekdays.removeAll { $0 == day }
                                    if included { routine.weekdays.append(day) }
                                })).toggleStyle(.checkbox).accessibilityLabel("Repeat on \(day.title)").help(day.title)
                            }
                        }.padding(.vertical, 5)
                    }
                    Text("\(routine.scheduleSummary) · One occurrence per selected day, in \(store.settings.timeZone).").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                }
                Section("Time & priority") {
                    Stepper("Duration: \(routine.minutes) minutes", value: $routine.minutes, in: 5...480, step: 5)
                    MinutePicker(title: "Allowed from", minute: $routine.startMinute)
                    MinutePicker(title: "Allowed until", minute: $routine.endMinute, includesEndOfDay: true)
                    Toggle("Protect this time", isOn: $routine.protected)
                    Toggle("Important to me", isOn: $routine.important)
                    Toggle("Urgent", isOn: $routine.urgent)
                    DetailNote("Scheduling details", "Placed within your workday and this window. Protected routines reserve time before tasks; flexible routines fit around priority work.")
                }
            }.formStyle(.grouped)
            VStack(alignment: .leading, spacing: 14) {
                if let message = routine.validationMessage {
                    Text(message).font(Theme.body(11)).foregroundStyle(Theme.alert).accessibilityLabel(message)
                } else {
                    DetailNote("Applying changes", "Replan to apply changes. Turning off a day or this routine removes its unstarted blocks, including pins. Completed and running occurrences stay.")
                }
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(isNew ? "Create routine" : "Save routine") {
                        if store.saveRoutine(routine) { dismiss() }
                    }.buttonStyle(GoldButton()).disabled(routine.validationMessage != nil).keyboardShortcut(.defaultAction)
                }
            }.padding(22)
        }.frame(width: 640, height: 740).background(Theme.background).foregroundStyle(Theme.text).font(Theme.body())
    }
}

struct RoutinesView: View {
    @EnvironmentObject var store: PlannerStore
    private struct EditorRequest: Identifiable {
        let routine: Routine
        let isNew: Bool
        var id: String { routine.id }
    }
    @State private var editing: EditorRequest?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Routines").font(Theme.display(30))
                    }
                    Spacer(minLength: 0)
                    Button { newRoutine() } label: { Label("New routine", systemImage: "plus") }.buttonStyle(GoldButton()).fixedSize()
                }
                DividerLine()
                ForEach(store.routines) { routine in
                    HStack(alignment: .center, spacing: 24) {
                        Image(systemName: routine.kind.symbol).font(.system(size: 32, weight: .ultraLight)).foregroundStyle(Theme.gold).frame(width: 54)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(routine.title).font(Theme.display(24)).fixedSize(horizontal: false, vertical: true)
                            Text("\(routine.scheduleSummary) · \(routine.minutes) min · \(time(routine.startMinute))–\(time(routine.endMinute))").font(Theme.body(12)).foregroundStyle(Theme.secondary)
                            HStack {
                                Tag(title: routine.enabled ? (routine.protected ? "PROTECTED" : "FLEXIBLE") : "NOT ENABLED")
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Edit") { editing = EditorRequest(routine: routine, isNew: false) }.buttonStyle(QuietButton()).accessibilityLabel("Edit routine \(routine.title)")
                    }.padding(.vertical, 12)
                    DividerLine()
                }
            }.padding(36).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.sheet(item: $editing) { RoutineEditor(routine: $0.routine, isNew: $0.isNew) }
    }
    private func newRoutine() {
        let routine = Routine(title: "", minutes: 15, startMinute: store.settings.workStart, endMinute: store.settings.workEnd, enabled: true)
        editing = EditorRequest(routine: routine, isNew: true)
    }
    private func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}
