import Foundation
import RingCore

extension PlannerStore {
    func canEditCalendarEvent(_ event: CalendarGridEvent) -> Bool {
        guard !event.allDay, event.category == .task || event.category == .routine,
              event.status != .completed, event.status != .interrupted,
              let owner = event.planID, let blockID = event.blockID,
              !publishingCalendar, !calendarEditSending,
              !calendarEdits.contains(where: { $0.unresolved && $0.publication.day == owner && $0.event.blockID == blockID }) else { return false }
        if let taskID = event.taskID {
            guard let task = tasks.first(where: { $0.id == taskID }), task.state == .ready || task.state == .waiting else { return false }
        }
        if plans.flatMap(\.blocks).contains(where: { b in
            b.start == event.start && b.end == event.end && b.state != .planned &&
            ((event.taskID != nil && b.taskID == event.taskID) || (event.routineID != nil && b.routineID == event.routineID))
        }) { return false }
        if let block = plans.first(where: { $0.id == owner })?.blocks.first(where: { $0.id == blockID }) { return block.state == .planned }
        return event.googleEventID != nil && (event.taskID != nil || event.routineID != nil)
    }
    @discardableResult func editCalendarEvent(_ event: CalendarGridEvent, start: Date, end: Date) async -> Bool {
        guard canEditCalendarEvent(event), CalendarBlockEditing.valid(start: start, end: end),
              let owner = event.planID, let blockID = event.blockID else { return false }
        if event.start == start && event.end == end { return true }
        // Resolve the destination before saving; recheck after the await to reject stale UI actions.
        await refreshPublishingSettings()
        guard canEditCalendarEvent(event) else { return false }
        let destination = plans.first { $0.id == owner }?.publication?.destination ?? publicationDestinations.first { $0.id == event.calendarID } ?? publicationDestination
        guard let destination else { error = CalendarPublicationError.destination.localizedDescription; return false }
        var p: DayPlan
        if let saved = plans.first(where: { $0.id == owner }) { p = saved }
        else {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = calendar; f.timeZone = calendar.timeZone
            guard let day = f.date(from: owner) else { return false }
            p = Scheduler().makePlan(day: day, now: now, tasks: [], routines: [], settings: settings); p.blocks = []
        }
        let existing = p.blocks.firstIndex { $0.id == blockID }
        if let existing, (p.blocks[existing].start != event.start || p.blocks[existing].end != event.end) {
            // Google range reads may be newer than the owner plan. Adopt only authenticated identity.
            let baseline = p.publication?.desired.first { $0.blockID == blockID }
            guard event.googleEventID != nil, baseline?.start == p.blocks[existing].start, baseline?.end == p.blocks[existing].end else { error = "This block changed. Refresh the calendar and try again."; return false }
        }
        var block = existing.map { p.blocks[$0] } ?? PlanBlock(id: blockID, title: event.title, context: "", kind: event.category == .task ? .focus : .routine, start: event.start, end: event.end, taskID: event.taskID, routineID: event.routineID)
        block.start = start; block.end = end; block.pinned = true; block.calendarOwnerDay = owner
        if let existing { p.blocks[existing] = block } else { p.blocks.append(block) }
        if p.publication == nil {
            p.publication = CalendarPublication(plan: p, workspaceID: workspaceID, destination: destination, timeZone: settings.timeZone, confirmedBlockIDs: [blockID])
        }
        guard let desired = CalendarPlanEvent.events(plan: p, workspaceID: workspaceID, timeZone: settings.timeZone).first(where: { $0.blockID == blockID }),
              event.googleEventID == nil || event.googleEventID == desired.id else { error = CalendarPublicationError.foreignEvent.localizedDescription; return false }
        let existed = event.googleEventID != nil || p.publication!.lastPublishedEvents?.contains(where: { $0.id == desired.id }) == true || p.publication!.publishedAt != nil && p.publication!.known.contains(where: { $0.id == desired.id })
        p.publication = CalendarBlockEditing.recording(desired, in: p.publication!, acknowledged: false)
        var scope = p.publication!; scope.desired = [desired]; scope.known = [desired]; scope.confirmedBlockIDs = [blockID]; scope.observedPlanEvents = [desired]
        let edit = CalendarBlockEdit(publication: scope, baselineStart: event.start, baselineEnd: event.end, creating: !existed)
        p.revision += 1; p = Scheduler().refreshingLayout(p, settings: settings)
        // An older imported plan may contain an unstarted copy with a different block ID.
        // Once its authenticated Google occurrence is adopted, retain only that occurrence.
        func removingLegacyCopy(_ plan: DayPlan) -> DayPlan {
            var value = plan
            value.blocks.removeAll { b in
                b.id != blockID && b.state == .planned && b.actualStartedAt == nil && b.start == event.start && b.end == event.end &&
                ((event.taskID != nil && b.taskID == event.taskID && b.routineID == nil) || (event.routineID != nil && b.routineID == event.routineID && b.taskID == nil))
            }
            if value.blocks != plan.blocks { value.revision += 1; value = Scheduler().refreshingLayout(value, settings: settings) }
            return value
        }
        let legacyUpdates = existing == nil && event.googleEventID != nil ? plans.filter { $0.id != owner }.compactMap { old -> DayPlan? in let value = removingLegacyCopy(old); return value == old ? nil : value } : []
        if existing == nil && event.googleEventID != nil { p = removingLegacyCopy(p) }
        let changed = tasks.first { $0.id == event.taskID }.map { CalendarBlockEditing.resizedTask($0, from: event.minutes, to: Int(end.timeIntervalSince(start) / 60), now: now) }
        guard persist(message: "Move or resize calendar occurrence and queue Google sync", tasks: changed.map { [$0] } ?? [], calendarEdits: [edit], plan: p, plans: legacyUpdates, apply: {
            if let changed, let i = self.tasks.firstIndex(where: { $0.id == changed.id }) { self.tasks[i] = changed }
        }) else { return false }
        calendarGridRevision = UUID()
        await retryCalendarEdits(force: true)
        return true
    }
    func retryCalendarEdits(force: Bool = false) async {
        guard !publishingCalendar, !calendarEditSending else { return }
        let pending = calendarEdits.filter { $0.state == .pending && (force || ($0.nextAttemptAt ?? .distantPast) <= Date()) }
        guard !pending.isEmpty else { return }
        publishingCalendar = true; calendarEditSending = true
        defer { publishingCalendar = false; calendarEditSending = false; calendarGridRevision = UUID() }
        for original in pending {
            var edit = original
            guard let owner = plans.first(where: { $0.id == edit.publication.day }),
                  let block = owner.blocks.first(where: { $0.id == edit.event.blockID }), block.state == .planned,
                  block.start == edit.event.start, block.end == edit.event.end,
                  edit.event.taskID == nil || tasks.contains(where: { $0.id == edit.event.taskID && ($0.state == .ready || $0.state == .waiting) }) else {
                edit.state = .cancelled; edit.lastError = "The task changed before this calendar edit could be sent."
                _ = persist(message: "Cancel stale calendar edit", calendarEdits: [edit], apply: {}); continue
            }
            do {
                if !isDemo { try await googleCalendar.applyBlockEdit(edit) }
                edit.state = .synced; edit.syncedAt = Date(); edit.lastError = nil; edit.nextAttemptAt = nil
                var p = plans.first { $0.id == edit.publication.day }!
                if let publication = p.publication {
                    p.publication = CalendarBlockEditing.recording(edit.event, in: publication, acknowledged: true)
                    if p.publication!.missingEventIDs?.isEmpty != false && p.publication!.desired.allSatisfy({ p.publication!.lastPublishedEvents?.contains($0) == true }) {
                        p.publication!.state = .published; p.publication!.publishedAt = Date(); p.publication!.lastError = nil
                    }
                }
                guard persist(message: "Acknowledge Google calendar occurrence edit", calendarEdits: [edit], plan: p, apply: {}) else { return }
                if isDemo {
                    calendarGridDemoEvents.removeAll { $0.sourceEventID == edit.event.id }
                    calendarGridDemoEvents.append(CalendarOccurrence(id: edit.event.id, calendarID: edit.publication.destination.id, title: edit.event.title, calendarTitle: "Example calendar", start: edit.event.start, end: edit.event.end, managedByPlanner: true, plannerCategory: edit.event.category, plannerTaskID: edit.event.taskID, plannerRoutineID: edit.event.routineID, plannerBlockID: edit.event.blockID, plannerDay: edit.publication.day))
                }
                showNotice(isDemo ? "Example calendar updated." : "Calendar updated.")
            } catch {
                edit.attempts += 1; edit.lastError = error.localizedDescription
                if let reason = error as? CalendarPublicationError {
                    switch reason { case .conflict, .removedEvent, .foreignEvent, .invalidPlan, .account, .destination: edit.state = .conflict }
                }
                edit.nextAttemptAt = Date().addingTimeInterval(min(900, 30 * pow(2, Double(min(5, edit.attempts)))))
                guard persist(message: "Keep pending Google calendar edit", calendarEdits: [edit], apply: {}) else { return }
            }
        }
    }
    /// Read again before either resolution; an explicit local override still uses Google's latest ETag.
    func resolveCalendarEdit(_ original: CalendarBlockEdit, useGoogle: Bool) async {
        guard !publishingCalendar, !calendarEditSending, original.unresolved else { return }
        calendarEditSending = true
        do {
            guard let time = try await googleCalendar.eventTimes(original.publication).first else { throw CalendarPublicationError.removedEvent }
            guard calendarEdits.first(where: { $0.id == original.id }) == original else { calendarEditSending = false; return }
            var edit = original
            if useGoogle {
                guard var p = plans.first(where: { $0.id == edit.publication.day }), let i = p.blocks.firstIndex(where: { $0.id == edit.event.blockID }), p.blocks[i].state == .planned else { throw CalendarPublicationError.invalidPlan }
                let oldMinutes = p.blocks[i].minutes
                p.blocks[i].start = time.start; p.blocks[i].end = time.end; p.blocks[i].pinned = true
                p.revision += 1; p = Scheduler().refreshingLayout(p, settings: settings)
                if let pub = p.publication { p.publication = CalendarBlockEditing.recording(edit.event.rescheduled(start: time.start, end: time.end), in: pub, acknowledged: true) }
                let task = tasks.first { $0.id == edit.event.taskID }.map { CalendarBlockEditing.resizedTask($0, from: oldMinutes, to: Int(time.end.timeIntervalSince(time.start) / 60), now: now) }
                edit.state = .cancelled
                _ = persist(message: "Use Google time for calendar occurrence", tasks: task.map { [$0] } ?? [], calendarEdits: [edit], plan: p) {
                    if let task, let i = self.tasks.firstIndex(where: { $0.id == task.id }) { self.tasks[i] = task }
                }
            } else {
                edit.baselineStart = time.start; edit.baselineEnd = time.end; edit.creating = false; edit.state = .pending; edit.lastError = nil; edit.nextAttemptAt = nil
                _ = persist(message: "Retry calendar edit with reviewed Google baseline", calendarEdits: [edit], apply: {})
            }
        } catch { self.error = error.localizedDescription }
        calendarEditSending = false; calendarGridRevision = UUID()
        if !useGoogle { await retryCalendarEdits(force: true) }
    }
}
