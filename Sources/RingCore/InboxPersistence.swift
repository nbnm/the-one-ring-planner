import Foundation

extension DataRepository {
    public func loadInbox() throws -> [InboxItem] {
        try withExclusiveAccess {
            let items = try load(InboxItem.self, directory: "inbox-items")
            for item in items { try item.validate() }; return items.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        }
    }
    @discardableResult public func saveInbox(_ item: InboxItem, expectedRevision: Int?, attachments: [RepositoryAttachmentWrite] = []) throws -> InboxItem {
        try withExclusiveAccess {
            try recoverPendingWrites()
            let current = try loadInbox().first { $0.id == item.id }
            if current == item { return item }
            let sameSource = current.map { $0.text == item.text && $0.sourceURL == item.sourceURL && $0.attachments == item.attachments && $0.createdAt == item.createdAt } ?? true
            // A retained draft can be replayed after its saved item has already been classified or moved.
            if expectedRevision == nil, sameSource, let current { return current }
            guard sameSource else { throw LibraryError.invalid("The original Inbox capture cannot be overwritten. Save changed source material as a new capture.") }
            guard current?.revision == expectedRevision, current?.route == nil else { throw LibraryError.stale }
            try save(inboxItems: [item], attachments: attachments, message: current == nil ? "Capture Inbox reference" : "Organize Inbox reference")
            return item
        }
    }
    /// Destination and routing receipt are one journal/commit, including recovery after failed Git commits.
    public func routeInbox(_ snapshot: InboxItem, as kind: InboxKind, task draft: PlannerTask? = nil, settings: PlanningSettings) throws -> (item: InboxItem, task: PlannerTask?, note: LibraryNote?) {
        try withExclusiveAccess {
            try recoverPendingWrites()
            guard var current = try loadInbox().first(where: { $0.id == snapshot.id }) else { throw LibraryError.stale }
            if let route = current.route {
                guard route.kind == kind else { throw LibraryError.stale }
                let task = kind == .task ? try load(PlannerTask.self, directory: "tasks").first { $0.id == route.recordID } : nil
                let note = kind == .note ? try loadLibrary().notes.first { $0.id == route.recordID } : nil
                guard task != nil || note != nil else { throw LibraryError.invalid("The routed record is missing. Restore it before retrying this move.") }
                return (current, task, note)
            }
            let onlySuggestionChanged = current.text == snapshot.text && current.attachments == snapshot.attachments && current.sourceURL == snapshot.sourceURL && current.createdAt == snapshot.createdAt && current.titleOverride == snapshot.titleOverride && current.tagsOverride == snapshot.tagsOverride
            guard (current.revision == snapshot.revision || onlySuggestionChanged), current.active, kind != .unknown else { throw LibraryError.stale }
            guard !current.awaitingTranscription else { throw LibraryError.invalid("Wait for the voice transcript, or retry transcription, before moving this capture.") }
            var tasks: [PlannerTask] = [], notes: [LibraryNote] = [], captures: [Capture] = []
            if kind == .task {
                guard var ready = draft.flatMap(TaskTriage.readyForPlacement), ready.id == current.id else { throw LibraryError.invalid("Confirm priority and duration before moving into the matrix.") }
                guard try !load(PlannerTask.self, directory: "tasks").contains(where: { $0.id == ready.id }) else { throw LibraryError.stale }
                var capture = Capture(text: current.content, timeZone: settings.timeZone, taskIDs: [ready.id], now: current.createdAt)
                capture.id = current.id; capture.attachments = current.attachments.isEmpty ? nil : current.attachments
                if ready.tags == snapshot.tags { ready.tags = current.tags }
                ready.attachments = current.attachments; ready.sourceCaptureID = capture.id
                tasks = [ready]; captures = [capture]
            } else {
                guard try !loadLibrary().notes.contains(where: { $0.id == current.id }) else { throw LibraryError.stale }
                notes = [current.note()]
            }
            current.revision += 1; current.route = InboxRoute(kind: kind, recordID: current.id)
            try save(tasks: tasks, captures: captures, notes: notes, inboxItems: [current], message: kind == .task ? "Place Inbox item in priority matrix" : "Place Inbox item in Library")
            return (current, tasks.first, notes.first)
        }
    }
}

extension DataRepository {
    public func moveLegacyInboxTaskToLibrary(_ snapshot: PlannerTask) throws -> (note: LibraryNote, plans: [DayPlan], edits: [CalendarBlockEdit]) {
        try withExclusiveAccess {
            try recoverPendingWrites()
            let hash = LibraryHash.digest(Data(("legacy-inbox:" + snapshot.id).utf8)), raw = String(hash.prefix(32))
            let chars = Array(raw)
            let noteID = [String(chars[0..<8]),String(chars[8..<12]),String(chars[12..<16]),String(chars[16..<20]),String(chars[20..<32])].joined(separator: "-")
            let existingNote = try loadLibrary().notes.first { $0.id == noteID }
            let task = try load(PlannerTask.self, directory: "tasks").first { $0.id == snapshot.id }
            if let existingNote, task == nil { return (existingNote, try load(DayPlan.self, directory: "plans"), try load(CalendarBlockEdit.self, directory: "calendar-edits")) }
            guard existingNote == nil, let task, task.state == .inbox, task.revision == snapshot.revision else { throw LibraryError.stale }
            let captures = try load(Capture.self, directory: "captures"), plans = try load(DayPlan.self, directory: "plans")
            let capture = captures.first { $0.id == task.sourceCaptureID }
            let text = capture?.text ?? (task.notes.isEmpty ? task.title : task.title + "\n\n" + task.notes)
            let comments = [task.notes == text ? "" : task.notes, task.context.isEmpty ? "" : "Context: " + task.context].filter { !$0.isEmpty }.joined(separator: "\n\n")
            var note = LibraryNote(id: noteID, title: task.title, body: text, comments: comments, sourceURL: ReferenceLinks.extract(text).first?.absoluteString ?? "", attachments: task.attachments,
                originals: [LibraryOriginal(id: "legacy-task:" + task.id, text: text, comments: comments, attachmentHashes: task.attachments.map(\.hash), channel: "legacy-inbox-task", capturedAt: task.createdAt)], now: task.createdAt)
            note.tags = task.tags
            let change = TaskLifecycle.change(task, to: .delete, plans: plans, captures: captures, now: Date())
            let planning = try settings()
            let changedPlans = change.plans.map { original -> DayPlan in
                var value = Scheduler().refreshingLayout(CalendarSchedule.canonical(original), settings: planning)
                if let publication = value.publication { value.publication = publication.invalidatingChanges(in: value, timeZone: planning.timeZone) }; return value
            }
            let edits = try load(CalendarBlockEdit.self, directory: "calendar-edits").filter { $0.unresolved && $0.event.taskID == task.id }.map { original -> CalendarBlockEdit in var edit = original; edit.state = .cancelled; edit.lastError = nil; edit.nextAttemptAt = nil; return edit }
            try save(captures: change.captures, calendarEdits: edits, plans: changedPlans, deletingTaskIDs: change.deletingTaskIDs, notes: [note], message: "Move existing Inbox task to Library")
            return (note, try load(DayPlan.self, directory: "plans"), try load(CalendarBlockEdit.self, directory: "calendar-edits"))
        }
    }
}
