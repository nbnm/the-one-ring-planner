import SwiftUI
import RingCore

struct CalendarTimeEditor: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let event: CalendarGridEvent
    @State private var start: Date
    @State private var end: Date
    @State private var saving = false
    init(event: CalendarGridEvent) { self.event = event; _start = State(initialValue: event.start); _end = State(initialValue: event.end) }
    private var valid: Bool { CalendarBlockEditing.valid(start: start, end: end) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move or resize").font(Theme.display(25))
            Text(event.title).font(Theme.body(14, weight: .semibold))
            DatePicker("Starts", selection: $start, displayedComponents: [.date, .hourAndMinute])
                .onChange(of: start) { old, new in end = end.addingTimeInterval(new.timeIntervalSince(old)) }
            DatePicker("Ends", selection: $end, displayedComponents: [.date, .hourAndMinute])
            Text(valid ? "\(store.duration(Int(end.timeIntervalSince(start) / 60))) · \(store.settings.timeZone)" : "Choose a duration from 5 minutes to 24 hours.").font(Theme.body(12)).foregroundStyle(valid ? Theme.secondary : Theme.alert)
            Text(event.category == .routine ? "Updates this routine occurrence and its Google event." : "Updates this task block, its duration estimate and its Google event.").font(Theme.body(12)).foregroundStyle(Theme.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
                Spacer()
                Button(saving ? "Saving…" : "Save & sync") {
                    saving = true
                    Task { let saved = await store.editCalendarEvent(event, start: start, end: end); saving = false; if saved { dismiss() } }
                }.keyboardShortcut(.defaultAction).buttonStyle(GoldButton()).disabled(!valid || saving)
            }
        }.padding(26).frame(width: 430).background(Theme.background).foregroundStyle(Theme.text)
            .environment(\.timeZone, store.calendar.timeZone)
    }
}

struct CalendarEditSyncPanel: View {
    @EnvironmentObject var store: PlannerStore
    private var edits: [CalendarBlockEdit] { store.calendarEdits.filter(\.unresolved) }
    var body: some View {
        if !edits.isEmpty {
          DisclosureGroup("\(edits.count) calendar \(edits.count == 1 ? "change" : "changes")") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(edits) { edit in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: edit.state == .conflict ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath").foregroundStyle(edit.lastError == nil ? Theme.gold : Theme.alert)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(edit.event.title + (edit.state == .conflict ? " · Review calendar change" : " · Waiting to sync")).font(Theme.body(11, weight: .semibold))
                            if let message = edit.lastError { Text(message).font(Theme.body(10)).foregroundStyle(Theme.secondary).lineLimit(2).help(message) }
                        }
                        Spacer(minLength: 6)
                        if edit.state == .conflict {
                            Button("Use Google time") { Task { await store.resolveCalendarEdit(edit, useGoogle: true) } }
                            Button("Apply my time") { Task { await store.resolveCalendarEdit(edit, useGoogle: false) } }
                        } else {
                            Button("Retry") { Task { await store.retryCalendarEdits(force: true) } }
                        }
                        if !store.calendarWritingAllowed && !store.isDemo { Button("Calendar settings") { store.page = .settings } }
                    }.buttonStyle(.plain).font(Theme.body(11)).foregroundStyle(Theme.gold)
                }
            }.disabled(store.calendarEditSending || store.publishingCalendar)
                .padding(12).background(Theme.gold.opacity(0.06), in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 24).padding(.bottom, 10)
          }.font(Theme.body(11)).padding(.horizontal, 24).padding(.bottom, 8)
        }
    }
}
