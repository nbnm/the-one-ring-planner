import SwiftUI
import RingCore
import Combine

@MainActor final class PlannerStore: ObservableObject {
    @Published var tasks: [PlannerTask] = []
    @Published var completions: [TaskCompletion] = []
    @Published var routines: [Routine] = []
    @Published var plans: [DayPlan] = []
    @Published var settings = PlanningSettings()
    @Published var editingTask: PlannerTask?
    @Published var priorityReview: PriorityReviewRequest?
    @Published var planningSelection: PlanSelectionRequest?
    @Published var taskSlotRequest: TaskSlotRequest?
    @Published var taskDrag: TaskDragSession?
    @Published var expandedQuadrant: Quadrant?
    var priorityDropRegions: [Quadrant: CGRect] = [:]
    @Published var captureReview: CaptureReview?
    @Published var page: Page = .today
    @Published var selectedDay = Date()
    @Published var now = Date()
    @Published var error: String?
    @Published var notice: String?
    @Published var savedAt: Date?
    @Published var celebration: Routine?
    @Published var taskCelebration: TaskCompletionFeedback?
    private let completionSound = TaskCompletionSound()
    @Published var inboxDraft = "" { didSet { taskCapture.text = inboxDraft } }
    @Published var buildingPlan = false
    @Published var publishingCalendar = false
    @Published var enablingCalendarWriting = false
    @Published var calendarWritingAllowed = false
    @Published var publicationDestinations: [PublicationDestination] = []
    @Published var publicationCalendarID = ""
    @Published var publicationSettingsError: String?
    @Published var updatingCalendarColors = false
    @Published var calendarColorNotice: String?
    @Published var calendarColorError: String?
    @Published var syncingCalendarSchedule = false
    @Published var calendarScheduleError: String?
    @Published var calendarDisplayError: String?
    var calendarScheduleReadFailed = false
    @Published var calendarScheduleLastRead: Date?
    @Published var calendarEdits: [CalendarBlockEdit] = []
    @Published var calendarGridRevision = UUID()
    @Published var calendarEditSending = false
    var calendarGridDemoEvents: [CalendarOccurrence] = []
    var taskSlotCalendarCache: TaskSlotCalendarSnapshot?
    var calendarScheduleTask: Task<Void, Never>?
    let taskCapture: TaskCaptureAssets
    private var taskCaptureUpdates: AnyCancellable?
    let captureAI: CaptureAISettings
    let library: LibraryStore
    let telegram: TelegramStore
    private var telegramUpdates: AnyCancellable?
    let sharedInbox: SharedInboxStore
    private var sharedInboxUpdates: AnyCancellable?
    var libraryDropRegions: [CGRect] = []
    @Published var captureDestination = CaptureDestination.inbox
    private var libraryUpdates: AnyCancellable?
    let meetings: MeetingStore
    let eventAlerts: EventAlerts
    var eventAlertUpdates: AnyCancellable?
    var eventAlertRead: (revision: UUID, read: CalendarRead)?
    private var meetingUpdates: AnyCancellable?
    let googleCalendar: GoogleCalendarProvider
    let calendarConnection: CalendarConnection
    let repository: DataRepository?
    let workspaceID: String
    let publicationDefaults: UserDefaults
    let isDemo: Bool
    private var clock: Timer?
    private var calendarTimer: Timer?
    private var publicationTimer: Timer?
    private var calendarUpdates: AnyCancellable?
    enum Page: String, CaseIterable {
        case today = "Today", inbox = "Inbox", calendar = "Calendar", matrix = "Priority matrix", routines = "Routines", meetings = "The Eye", library = "Library", review = "Daily review", history = "History", settings = "Settings"
        var icon: String { switch self { case .today: return "sun.max"; case .inbox: return "tray"; case .calendar: return "calendar"; case .matrix: return "square.grid.2x2"; case .routines: return "sparkles"; case .meetings: return "eye"; case .library: return "books.vertical"; case .review: return "book.closed"; case .history: return "clock.arrow.circlepath"; case .settings: return "slider.horizontal.3" } }
    }
    init(demo: Bool = false) {
        isDemo = demo
        captureAI = CaptureAISettings(demo: demo)
        publicationDefaults = demo ? UserDefaults(suiteName: "com.t1a.publication-demo.\(UUID().uuidString)")! : .standard
        eventAlerts = EventAlerts(defaults: publicationDefaults, demo: demo)
        publicationCalendarID = publicationDefaults.string(forKey: "googleCalendar.publicationDestination") ?? ""
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("The One Ring Planner")
        var initialError: String?
        var localRepository: DataRepository?
        var identity = UUID().uuidString.lowercased()
        do {
            let selectedRoot = demo ? nil : UserDefaults.standard.string(forKey: "workspace.restoredRoot").map { URL(fileURLWithPath: $0) }
            let base = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("one-ring-preview-\(UUID().uuidString)") : (selectedRoot ?? support)
            localRepository = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
            identity = try localRepository!.workspaceID()
        } catch { initialError = error.localizedDescription; localRepository = nil }
        repository = localRepository; workspaceID = identity
        library = LibraryStore(repository: localRepository, ai: captureAI, demo: demo)
        sharedInbox = SharedInboxStore(repository: localRepository, library: library, demo: demo)
        telegram = TelegramStore(repository: localRepository, ai: captureAI, inbox: sharedInbox, demo: demo)
        taskCapture = TaskCaptureAssets(repository: localRepository)
        googleCalendar = GoogleCalendarProvider(oauth: GoogleOAuthClient(storage: GoogleKeychainStore(service: demo ? "com.t1a.the-one-ring-planner.demo.google-direct" : "com.t1a.the-one-ring-planner.google-direct")), workspaceID: identity)
        calendarConnection = CalendarConnection(provider: googleCalendar, defaults: demo ? UserDefaults(suiteName: "com.t1a.calendar-demo.\(UUID().uuidString)")! : .standard)
        let restoredMeetingRoot = !demo && publicationDefaults.bool(forKey: "workspace.restoredMeetings") ? publicationDefaults.string(forKey: "workspace.restoredRoot").map { URL(fileURLWithPath: $0).appendingPathComponent("Meetings") } : nil
        meetings = MeetingStore(root: demo ? FileManager.default.temporaryDirectory.appendingPathComponent("one-ring-meetings-demo-\(identity)") : (restoredMeetingRoot ?? support.appendingPathComponent("Meetings")), ai: captureAI, demo: demo)
        library.meetingsRoot = meetings.repository?.root
        if !demo && publicationDefaults.bool(forKey: "workspace.restoreNeedsReview") { calendarConnection.suspendForRestoredWorkspace() }
        self.error = initialError
        do {
            if let repository {
                settings = try repository.settings()
                tasks = try repository.load(PlannerTask.self, directory: "tasks")
                routines = try repository.load(Routine.self, directory: "routines")
                plans = try repository.load(DayPlan.self, directory: "plans")
                completions = try repository.load(TaskCompletion.self, directory: "completions")
                calendarEdits = try repository.load(CalendarBlockEdit.self, directory: "calendar-edits")
                let migration = TaskHistory.migratingLegacy(tasks: tasks, completions: completions, now: Date())
                if !migration.tasks.isEmpty {
                    try repository.save(tasks: migration.tasks, completions: migration.completions, message: "Preserve earlier completed tasks in History")
                    for task in migration.tasks { if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = task } }
                    completions += migration.completions
                }
                if routines.isEmpty {
                    try repository.save(routines: Routine.defaults, settings: settings, message: "Initialize local workspace")
                    routines = Routine.defaults
                }
            }
        } catch { self.error = error.localizedDescription }
        if demo {
            loadDemo()
            if CommandLine.arguments.contains("--middle-earth-demo") { loadMiddleEarthDemo() }
            if CommandLine.arguments.contains("--calendar-grid-demo") { loadCalendarGridDemo() }
            if CommandLine.arguments.contains("--q2-demo") {
                loadCalendarGridDemo()
                let task = PlannerTask(id: "q2-review-example", title: "Review the 8FDE delivery plan", context: "T1A", state: .ready, importance: true, urgency: false, remainingMinutes: 60)
                tasks.append(task); selectedDay = calendar.date(byAdding: .day, value: 14, to: now)!; page = .matrix
                offerTimeSlot(for: task)
            }
        }
        library.recordingIsActive = { [weak self] in guard let self else { return true }; return self.meetings.busy || self.buildingPlan || self.publishingCalendar || self.calendarEditSending }
        library.restoreSelection = { [weak self] root, includesMeetings in
            guard let self, !self.library.recordingIsActive(), !self.library.saving else { return }
            self.publicationDefaults.set(root.path, forKey: "workspace.restoredRoot")
            self.publicationDefaults.set(includesMeetings, forKey: "workspace.restoredMeetings")
            self.publicationDefaults.set(true, forKey: "workspace.restoreNeedsReview")
            self.showNotice("Restored workspace selected · quit and reopen to switch. Review calendar connections before enabling sync.")
        }
        telegram.command = { [weak self] text in
            guard let self else { return "Planner is unavailable." }
            if text.split(whereSeparator: \.isWhitespace).first?.split(separator: "@").first == "/status" { return "\(self.telegram.status)\nPending captures: \(self.telegram.state.jobs.count)" }
            return TelegramCommands.reply(text, tasks: self.tasks, plans: self.plans, inbox: self.sharedInbox.items, settings: self.settings, now: Date())
        }
        telegram.digest = { [weak self] day in guard let self else { return "Planner is unavailable." }; return TelegramCommands.plan(day, plans: self.plans, tasks: self.tasks, settings: self.settings, now: Date()) }
        telegram.urgent = { [weak self] in self?.tasks ?? [] }
        telegram.defaultAudioModel = { [weak self] in self?.meetings.audioModel ?? "" }
        telegram.reminders = { [weak self] in
            guard let self else { return [] }
            let date = Date()
            let events = self.calendarConnection.enabled ? try await self.calendarConnection.readRange(DateInterval(start: date.addingTimeInterval(-90), end: date.addingTimeInterval(3600))).events : []
            return EventReminderPlanner.reminders(events: events, plans: self.plans, tasks: self.tasks, now: date.addingTimeInterval(-90))
        }
        telegramUpdates = telegram.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send() } }
        telegram.start()
        sharedInbox.knownTags = { [weak self] in self?.knownTags ?? [] }
        inboxDraft = taskCapture.text
        sharedInboxUpdates = sharedInbox.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send() } }
        taskCaptureUpdates = taskCapture.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send() } }
        libraryUpdates = library.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send() } }
        if CommandLine.arguments.contains("--library-demo") || (demo && Bundle.main.object(forInfoDictionaryKey: "OneRingIsolatedDemo") as? Bool == true) { page = .library }
        meetings.importTasks = { [weak self] in self?.importMeetingTasks($0) ?? false }
        meetings.planningSettings = { [weak self] in self?.settings ?? PlanningSettings() }
        meetings.knownTags = { [weak self] in self?.knownTags ?? [] }
        meetings.recoverImports()
        meetingUpdates = meetings.objectWillChange.sink { [weak self] in Task { @MainActor in self?.objectWillChange.send() } }
        if CommandLine.arguments.contains("--inbox-demo") { page = .inbox }
        if CommandLine.arguments.contains("--meeting-demo") { page = .meetings }
        calendarConnection.onRefresh = { [weak self] _ in await self?.synchronizeCalendarSchedule() }
        calendarUpdates = calendarConnection.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isDemo { self.now = Date() }
                else if CommandLine.arguments.contains("--demo-live-clock") { self.now = self.now.addingTimeInterval(15) }
            }
        }
        if !demo {
            publicationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.retryPendingPublications() }
            }
            Task { [weak self] in await self?.retryPendingPublications() }
            calendarTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.calendarConnection.enabled, !self.calendarConnection.loading else { return }
                    await self.calendarConnection.refreshCurrentDay()
                }
            }
        }
    }
    var compactNavigation: Bool {
        get { publicationDefaults.object(forKey: "navigation.compact") as? Bool ?? true }
        set { objectWillChange.send(); publicationDefaults.set(newValue, forKey: "navigation.compact") }
    }
    var calendar: Calendar { PlannerDate.calendar(settings) }
    var nextPlanningDay: Date { PlannerDate.nextWorkingDay(after: now, settings: settings) }
    var dayKey: String { PlannerDate.key(selectedDay, settings: settings) }
    var plan: DayPlan? { plans.first { $0.id == dayKey } }
    var displayPlan: DayPlan? { CalendarSchedule.plan(on: selectedDay, plans: plans, settings: settings, now: now, forDisplay: true, tasks: tasks) }
    func planningPlan(on day: Date) -> DayPlan? { CalendarSchedule.plan(on: day, plans: plans, settings: settings, now: now) }
    var todayPlan: DayPlan? { CalendarSchedule.plan(on: now, plans: plans, settings: settings, now: now, forDisplay: true, tasks: tasks) }
    var inbox: [PlannerTask] { tasks.filter { $0.state == .inbox }.sorted { $0.createdAt < $1.createdAt } }
    var activeTasks: [PlannerTask] { tasks.filter { $0.state != .done && $0.state != .archived && $0.state != .inbox } }
    var completionSoundEnabled: Bool {
        get { publicationDefaults.object(forKey: "task.completionSoundEnabled") as? Bool ?? true }
        set { objectWillChange.send(); publicationDefaults.set(newValue, forKey: "task.completionSoundEnabled") }
    }
    var completedDayTasks: [TaskCompletion] { TaskHistory.completed(on: selectedDay, tasks: tasks, completions: completions, settings: settings) }
    var knownTags: [String] { TaskTags.all(in: tasks) }
    var planningCandidates: [PlannerTask] {
        tasks.filter { $0.isEligible && $0.quadrant != .reconsider && TaskTriage.missingRequirements($0).isEmpty }
            .sorted { a, b in a.quadrant == b.quadrant ? a.title.localizedStandardCompare(b.title) == .orderedAscending : (a.quadrant?.rawValue ?? 5) < (b.quadrant?.rawValue ?? 5) }
    }
    var calendarPlanNeedsRefresh: Bool {
        guard !isDemo, let plan, calendarConnection.connected, let meetings = try? calendarConnection.meetings(day: selectedDay, settings: settings) else { return false }
        return plan.blocks.filter { $0.kind == .meeting }.sorted { $0.id < $1.id } != meetings.sorted { $0.id < $1.id }
    }
    var running: PlanBlock? { plans.flatMap(\.blocks).first { $0.state == .running } }
    var nextBlock: PlanBlock? { todayPlan?.blocks.first { $0.end > now && $0.state == .planned && $0.kind != .transition && $0.kind != .lunch } }
    func time(_ date: Date) -> String { let f = DateFormatter(); f.timeZone = calendar.timeZone; f.dateFormat = "HH:mm"; return f.string(from: date) }
    func duration(_ minutes: Int) -> String { minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" : "\(minutes)m" }
    func dayTitle(_ date: Date) -> String { let f = DateFormatter(); f.timeZone = calendar.timeZone; f.dateFormat = "EEEE, MMMM d"; return f.string(from: date) }
    func dateChanged(_ amount: Int) { selectedDay = calendar.date(byAdding: .day, value: amount, to: selectedDay) ?? selectedDay }
    func saveInboxCapture() { Task { _ = await captureIntoInbox() } }
    func refineInboxTask(_ task: PlannerTask) {
        guard task.state == .inbox else { return }
        prepareCapture(task.title + (task.notes.isEmpty ? "" : "\n" + task.notes), replacing: task)
    }
    func prepareCapture(_ text: String, replacing original: PlannerTask? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taskCapture.preparing == 0, !clean.isEmpty || !taskCapture.files.isEmpty || !(original?.attachments.isEmpty ?? true) else { return }
        captureReview?.cancel()
        let review = CaptureReview(source: clean, originalTask: original, files: original == nil ? taskCapture.files : [], demo: isDemo)
        captureReview = review
        review.process(settings: captureAI, knownTags: knownTags, repository: repository)
    }
    @discardableResult func confirmCapture(_ review: CaptureReview) -> Bool {
        guard captureReview?.id == review.id, !review.processing, review.assetsReady else { return false }
        do {
            var original: PlannerTask?
            if let snapshot = review.originalTask {
                guard let current = tasks.first(where: { $0.id == snapshot.id }), current.revision == snapshot.revision, current.state == .inbox else {
                    review.message = "This task changed during review. Go back and refine its latest version."; return false
                }
                original = current
            }
            let batch = try ReviewedCapture(source: review.source, drafts: review.drafts, settings: settings, knownTags: knownTags, replacing: original, attachments: review.attachments)
            let saved = persist(message: "Confirm reviewed capture", tasks: batch.tasks, captures: [batch.capture], attachments: review.preparedAttachments.map(\.write)) {
                let changed = Set(batch.tasks.map(\.id))
                self.tasks.removeAll { changed.contains($0.id) }; self.tasks.append(contentsOf: batch.tasks)
                if original == nil && self.inboxDraft.trimmingCharacters(in: .whitespacesAndNewlines) == review.source { self.inboxDraft = ""; self.taskCapture.removeConfirmed(review.files) }
                self.captureReview = nil
                for task in batch.tasks { self.categorizeInventoryTask(task) }
                self.showNotice(original == nil ? (batch.tasks.count == 1 ? "Task added to Inbox" : "\(batch.tasks.count) tasks added to Inbox") : "Inbox task refined\(batch.tasks.count > 1 ? "; \(batch.tasks.count - 1) added" : "")")
            }
            if !saved { review.message = error ?? "Your tasks could not be saved. The drafts are preserved." }
            return saved
        } catch { review.message = error.localizedDescription; return false }
    }
    @discardableResult func update(_ task: PlannerTask) -> Bool {
        guard let current = tasks.first(where: { $0.id == task.id }), current.revision == task.revision else {
            error = "This task changed. Close its details and open the latest version."; return false
        }
        if task.state == .inbox && current.state != .inbox { return changeTask(task, to: .inbox) }
        if task.state == .archived && current.state != .archived { return changeTask(task, to: .archive) }
        if task.state == .done && current.state != .done { return changeTask(task, to: .complete) }
        if (current.state == .done || (current.state == .archived && current.completionID != nil)) && task.state != .done && task.state != .archived { return reopenTask(task, to: task.state) }
        var edited = task; edited.revision += 1; edited.updatedAt = Date()
        edited.tags = TaskTags.normalize(edited.tags, known: knownTags)
        return persist(message: "Update task", tasks: [edited]) {
            if let index = self.tasks.firstIndex(where: { $0.id == edited.id }) { self.tasks[index] = edited }
            if current.quadrant != .schedule && edited.quadrant == .schedule && edited.isEligible { self.offerTimeSlot(for: edited) }
        }
    }
    func updateTaskDrag(taskID: String, title: String, location: CGPoint) {
        guard (page == .matrix || page == .library || page == .inbox || page == .today), tasks.contains(where: { $0.id == taskID && $0.state != .done && $0.state != .archived }) || sharedInbox.active.contains(where: { "inbox:" + $0.id == taskID }) else { return }
        taskDrag = TaskDragSession(taskID: taskID, title: title, location: location)
    }
    func expandQuadrant(_ quadrant: Quadrant) {
        taskDrag = nil; page = .matrix; expandedQuadrant = quadrant
        AppActions.enterQuadrantFullScreen()
    }
    func closeExpandedQuadrant() {
        taskDrag = nil; expandedQuadrant = nil
        AppActions.leaveQuadrantFullScreen()
    }
    func priorityDropTarget(at location: CGPoint) -> Quadrant? {
        Quadrant.allCases.first { priorityDropRegions[$0]?.contains(location) == true }
    }
    func finishTaskDrag(taskID: String, location: CGPoint) {
        let active = taskDrag?.taskID == taskID
        taskDrag = nil
        guard active else { return }
        if libraryDropRegions.contains(where: { $0.contains(location) }) {
            if let item = sharedInbox.active.first(where: { "inbox:" + $0.id == taskID }) { placeInboxInLibrary(item) }
            else if let task = inbox.first(where: { $0.id == taskID }) { moveInboxTaskToLibrary(task) }
            return
        }
        guard page == .matrix, let quadrant = priorityDropTarget(at: location) else { return }
        if let item = sharedInbox.active.first(where: { "inbox:" + $0.id == taskID }) { placeInbox(item, in: quadrant) }
        else { assignPriority(taskID: taskID, quadrant: quadrant) }
    }
    /// Both drag-and-drop and dropdowns use this gate; no partial classification is persisted.
    func assignPriority(taskID: String, quadrant: Quadrant) {
        guard let task = tasks.first(where: { $0.id == taskID }), task.state != .done, task.state != .archived else { return }
        let proposed = TaskTriage.proposing(task, quadrant: quadrant)
        if TaskTriage.missingRequirements(proposed).isEmpty { _ = commitPriority(proposed, expectedRevision: task.revision) }
        else { priorityReview = PriorityReviewRequest(task: proposed, originalRevision: task.revision) }
    }
    @discardableResult func commitPriority(_ draft: PlannerTask, expectedRevision: Int) -> Bool {
        guard let current = tasks.first(where: { $0.id == draft.id }), current.revision == expectedRevision else {
            error = "This task changed while you were reviewing it. Cancel and review its latest details."; return false
        }
        guard var reviewed = TaskTriage.readyForPlacement(draft), let quadrant = reviewed.quadrant else { return false }
        reviewed.tags = TaskTags.normalize(reviewed.tags, known: knownTags)
        reviewed.revision = current.revision + 1; reviewed.updatedAt = Date()
        return persist(message: "Assign task priority", tasks: [reviewed]) {
            self.applyTasks([reviewed])
            self.showNotice("Moved to Q\(quadrant.rawValue) · \(quadrant.title). Replan when ready.")
            if quadrant == .schedule && current.quadrant != .schedule { self.offerTimeSlot(for: reviewed) }
        }
    }
    @discardableResult func changeTask(_ draft: PlannerTask, to disposition: TaskDisposition) -> Bool {
        if (disposition == .complete || disposition == .backlog) && (publishingCalendar || calendarEditSending) {
            error = "Wait for the calendar update to finish, then try again."; return false
        }
        guard let current = tasks.first(where: { $0.id == draft.id }), current.revision == draft.revision else {
            error = "This task changed. Close its details and open the latest version."; return false
        }
        if disposition == .complete && current.state == .done { return true }
        if disposition == .inbox && current.completionID != nil && (current.state == .done || current.state == .archived) { return reopenTask(draft) }
        if disposition == .backlog && current.completionID != nil && (current.state == .done || current.state == .archived) { return reopenTask(draft, to: .ready) }
        var task = disposition == .delete ? current : draft
        if disposition == .complete { task.state = current.state; task.completedAt = current.completedAt; task.completionID = current.completionID }
        task.tags = TaskTags.normalize(task.tags, known: knownTags)
        do {
            let captures: [Capture] = disposition == .delete ? try repository?.load(Capture.self, directory: "captures") ?? [] : []
            let change = TaskLifecycle.change(task, to: disposition, plans: plans, captures: captures, now: isDemo ? now : Date())
            let changedPlans = disposition == .complete || disposition == .backlog ? change.plans.map { Scheduler().refreshingLayout($0, settings: settings, tasks: tasks) } : change.plans
            let message = disposition == .complete ? "Complete task and save history" : disposition == .delete ? "Delete task" : disposition == .archive ? "Archive task" : disposition == .backlog ? "Return task to backlog" : "Move task to Inbox"
            let cancelledEdits = (disposition == .complete || disposition == .backlog) ? cancelledTaskCalendarEdits(task.id) : []
            return persist(message: message, tasks: change.task.map { [$0] } ?? [], captures: change.captures,
                           completions: change.completions, calendarEdits: cancelledEdits, plans: changedPlans, deletingTaskIDs: change.deletingTaskIDs) {
                self.taskDrag = nil
                if let task = change.task { self.applyTasks([task]) }
                else { self.tasks.removeAll { $0.id == current.id } }
                for plan in changedPlans { self.applyPlan(plan) }
                self.calendarGridRevision = UUID()
                self.showNotice(disposition == .complete ? "Completed · saved in History" : disposition == .delete ? "Task deleted" : disposition == .archive ? "Task archived" : disposition == .backlog ? "Back in backlog · priority kept" : "Moved to Inbox")
                if (disposition == .complete || disposition == .backlog) && changedPlans.contains(where: { $0.publication != nil }) {
                    self.showNotice(disposition == .complete ? "Completed · confirm plan to update Google Calendar" : "Back in backlog · confirm plan to update Google Calendar")
                }
                if disposition == .complete, let entry = change.completions.first { self.celebrateCompletion(entry) }
            }
        } catch { self.error = error.localizedDescription; return false }
    }
    func archive(_ task: PlannerTask) { _ = changeTask(task, to: .archive) }
    @discardableResult func completeTask(_ task: PlannerTask) -> Bool { changeTask(task, to: .complete) }
    @discardableResult func returnToBacklog(_ task: PlannerTask) -> Bool { changeTask(task, to: .backlog) }
    private func reopenTask(_ draft: PlannerTask, to state: TaskState = .inbox) -> Bool {
        guard let current = tasks.first(where: { $0.id == draft.id }), current.revision == draft.revision,
              let entry = completions.first(where: { $0.id == current.completionID }) else { error = "Open History to restore this task’s latest completion."; return false }
        do {
            var base = draft; base.state = current.state; base.completionID = current.completionID
            var restoration = try TaskHistory.restore(entry, current: base, completions: completions, now: isDemo ? now : Date(), destination: state == .inbox ? .inbox : .backlog)
            if state != .inbox {
                restoration.task.state = state; restoration.task.importance = draft.importance; restoration.task.urgency = draft.urgency
                if let effort = draft.remainingMinutes, effort > 0 { restoration.task.remainingMinutes = effort }
            }
            return persist(message: "Restore completed task", tasks: [restoration.task], completions: [restoration.completion]) {
                self.applyTasks([restoration.task]); self.showNotice("Task restored. Completion history kept.")
            }
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func restoreCompletion(_ snapshot: TaskCompletion, destination: TaskRestorationDestination = .inbox) -> Bool {
        guard !publishingCalendar && !calendarEditSending else { error = "Wait for the calendar update to finish, then try again."; return false }
        guard let entry = completions.first(where: { $0.id == snapshot.id }), entry == snapshot else { error = "This history entry changed. Open it again."; return false }
        do {
            let restoration = try TaskHistory.restore(entry, current: tasks.first { $0.id == entry.taskID }, completions: completions, now: isDemo ? now : Date(), destination: destination)
            var captures: [Capture] = []
            if let source = restoration.task.sourceCaptureID, var capture = try repository?.load(Capture.self, directory: "captures").first(where: { $0.id == source }), !capture.taskIDs.contains(restoration.task.id) {
                capture.taskIDs.append(restoration.task.id); captures = [capture]
            }
            return persist(message: "Restore task from completion history", tasks: [restoration.task], captures: captures, completions: [restoration.completion]) {
                if self.tasks.contains(where: { $0.id == restoration.task.id }) { self.applyTasks([restoration.task]) } else { self.tasks.append(restoration.task) }
                self.showNotice(destination == .backlog ? "Back in backlog · priority and history kept" : "Restored to Inbox · completion history kept")
                if self.taskCelebration?.completion.id == entry.id { self.taskCelebration = nil }
            }
        } catch { self.error = error.localizedDescription; return false }
    }
    private func celebrateCompletion(_ entry: TaskCompletion) {
        taskCelebration = TaskCompletionFeedback(completion: entry)
        if completionSoundEnabled && meetings.activeID == nil && !meetings.finishing { completionSound.play() }
    }
    private func cancelledTaskCalendarEdits(_ taskID: String) -> [CalendarBlockEdit] {
        calendarEdits.filter { $0.unresolved && $0.event.taskID == taskID }.map { original in
            var edit = original; edit.state = .cancelled; edit.lastError = nil; edit.nextAttemptAt = nil; return edit
        }
    }
    @discardableResult func saveRoutine(_ draft: Routine) -> Bool {
        var routine = draft
        routine.title = routine.title.trimmingCharacters(in: .whitespacesAndNewlines)
        routine.weekdays = RoutineWeekday.allCases.filter { draft.weekdays.contains($0) }
        routine.schemaVersion = 2
        if let message = routine.validationMessage { error = message; return false }
        return persist(message: "Save routine preferences", routines: [routine]) {
            if let i = self.routines.firstIndex(where: { $0.id == routine.id }) { self.routines[i] = routine }
            else { self.routines.append(routine) }
            self.showNotice("Routine saved. Replan to apply it.")
        }
    }
    func saveSettings(_ value: PlanningSettings) {
        guard value.isValid else { error = "Check the work window, lunch and focus durations."; return }
        _ = persist(message: "Update planning settings", settings: value) { self.settings = value; self.showNotice("Preferences saved") }
    }
    func generate(outcomes: [String]? = nil) {
        let day = selectedDay, selection = plan?.selectedTaskIDs
        Task { _ = await buildDraft(day: day, outcomes: outcomes, selectedTaskIDs: selection) }
    }
    func chooseTasks(for day: Date) {
        selectedDay = day
        planningSelection = PlanSelectionRequest(day: day)
    }
    struct PlanningMeetings {
        let blocks: [PlanBlock]
        let readAt: Date?
    }
    func readPlanningMeetings(day: Date, settings snapshot: PlanningSettings) async throws -> PlanningMeetings {
        if isDemo {
            let key = PlannerDate.key(day, settings: snapshot)
            return PlanningMeetings(blocks: plans.first { $0.id == key }?.blocks.filter { $0.kind == .meeting } ?? [], readAt: nil)
        }
        guard calendarConnection.enabled else { return PlanningMeetings(blocks: [], readAt: nil) }
        guard !calendarConnection.selectedIDs.isEmpty else { throw CalendarConnectionError.selectCalendars }
        guard let read = await calendarConnection.refresh(day: day, settings: snapshot),
              calendarConnection.enabled, read.calendarIDs == calendarConnection.selectedIDs else {
            throw PlanningReadError.failed(calendarConnection.message ?? CalendarConnectionError.changedDuringRead.localizedDescription)
        }
        if calendarScheduleReadFailed, let calendarScheduleError { throw PlanningReadError.failed(calendarScheduleError) }
        return PlanningMeetings(blocks: try read.meetings(day: day, settings: snapshot, fullDay: true), readAt: Date())
    }
    @discardableResult func buildDraft(day: Date, outcomes: [String]? = nil, selectedTaskIDs: [String]?, confirmToCalendar: Bool = false) async -> Bool {
        guard !buildingPlan, !publishingCalendar else { return false }
        buildingPlan = true
        let settingsSnapshot = settings, key = PlannerDate.key(day, settings: settings)
        defer { buildingPlan = false }
            do {
                if confirmToCalendar && !isDemo {
                    await refreshPublishingSettings()
                    let destination = plan?.publication?.destination ?? publicationDestination
                    guard let destination else { throw CalendarPublicationError.destination }
                    if !calendarConnection.selectedIDs.contains(destination.id) { calendarConnection.select(destination.id, included: true) }
                }
                let meetings = try await readPlanningMeetings(day: day, settings: settingsSnapshot).blocks
                guard key == dayKey, settingsSnapshot == settings else { showNotice("The day changed. Build the draft for the selected day."); return false }
                let selection = selectedTaskIDs.map { ids in Array(Set(ids).intersection(planningCandidates.map(\.id))).sorted() }
                var p = Scheduler().makePlan(day: day, now: now, tasks: tasks, routines: routines, settings: settingsSnapshot, meetings: meetings, previous: planningPlan(on: day), outcomeIDs: outcomes ?? plan?.outcomeIDs ?? [], selectedTaskIDs: selection)
                if !isDemo && !calendarConnection.enabled { p.warnings.append("Calendar is not connected. Connect it in Settings to check meeting availability.") }
                return confirmToCalendar ? await confirmPlan(p, calendarChecked: true) : savePlan(p, message: "Save draft plan")
            } catch { self.error = error.localizedDescription; return false }
    }
    func toggleOutcome(_ task: PlannerTask) {
        var ids = plan?.outcomeIDs ?? []
        if ids.contains(task.id) { ids.removeAll { $0 == task.id } }
        else { if ids.count >= 3 { showNotice("Choose up to three outcomes"); return }; ids.append(task.id) }
        var selection = plan?.selectedTaskIDs
        if ids.contains(task.id), selection != nil, selection?.contains(task.id) == false { selection?.append(task.id) }
        let day = selectedDay
        Task { _ = await buildDraft(day: day, outcomes: ids, selectedTaskIDs: selection) }
    }
    func useLocalPlan() {
        guard let p = plan else { return }
        Task { _ = await confirmPlan(p) }
    }
    func pin(_ block: PlanBlock) {
        guard var p = ownerPlan(for: block), let i = p.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        p.blocks[i].pinned.toggle(); savePlan(p, message: "Change block pin")
    }
    func start(_ block: PlanBlock) {
        guard !calendarPlanNeedsRefresh else { error = "Calendar events changed. Replan before starting a new block."; return }
        guard running == nil else { error = "Pause or complete the current block before starting another."; return }
        guard dayKey == PlannerDate.key(now, settings: settings) else { error = "You can start blocks on today's plan."; return }
        guard var p = ownerPlan(for: block), let i = p.blocks.firstIndex(where: { $0.id == block.id }), block.state == .planned else { return }
        if let id = block.taskID, tasks.first(where: { $0.id == id })?.isEligible != true {
            error = "This task is no longer ready for execution. Review it or replan first."; return
        }
        p.blocks[i].state = .running; p.blocks[i].actualStartedAt = now
        var changed: [PlannerTask] = []
        if let id = block.taskID, var t = tasks.first(where: { $0.id == id }) { t.state = .inProgress; t.updatedAt = now; t.revision += 1; changed = [t] }
        _ = persist(message: "Start work block", tasks: changed, plan: p) { self.applyPlan(p); self.applyTasks(changed) }
    }
    func complete(_ block: PlanBlock) {
        guard !publishingCalendar && !calendarEditSending else { error = "Wait for the calendar update to finish, then try again."; return }
        finish(block, completed: true, remaining: nil, note: nil)
    }
    func pause(_ block: PlanBlock, remaining: Int, note: String) {
        finish(block, completed: false, remaining: remaining, note: note)
    }
    private func finish(_ block: PlanBlock, completed: Bool, remaining: Int?, note: String?) {
        guard block.state == .planned || block.state == .running else { return }
        guard var p = ownerPlan(for: block), let i = p.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        guard p.blocks[i].state == .planned || p.blocks[i].state == .running else { return }
        p.blocks[i].state = completed ? .completed : .interrupted
        let elapsed = block.actualStartedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) } ?? 0
        p.blocks[i].actualMinutes = completed ? block.minutes : min(block.minutes, elapsed)
        var changed: [PlannerTask] = []
        if let id = block.taskID, var t = tasks.first(where: { $0.id == id }) {
            if completed && t.state != .done && (t.remainingMinutes ?? 0) <= block.minutes {
                let allPlans = plans.map { $0.id == p.id ? p : $0 }
                let change = TaskLifecycle.change(t, to: .complete, plans: allPlans, now: isDemo ? now : Date(), completedBlockID: block.id)
                var affected = change.plans; if !affected.contains(where: { $0.id == p.id }) { affected.append(p) }
                affected = affected.map { Scheduler().refreshingLayout($0, settings: settings, tasks: tasks) }
                _ = persist(message: "Complete task block and save history", tasks: change.task.map { [$0] } ?? [], completions: change.completions, calendarEdits: cancelledTaskCalendarEdits(t.id), plans: affected) {
                    self.applyTasks(change.task.map { [$0] } ?? []); self.showNotice("Task completed · saved in History")
                    if let entry = change.completions.first { self.celebrateCompletion(entry) }
                }
                return
            }
            t.remainingMinutes = completed ? max(0, (t.remainingMinutes ?? 0) - block.minutes) : max(1, remaining ?? t.remainingMinutes ?? 25)
            t.state = t.remainingMinutes == 0 ? .done : .ready
            if let note { t.resumeNote = note }
            t.updatedAt = now; t.revision += 1; changed = [t]
            // Completion may make other planned chunks obsolete; never leave stale future work active.
            if t.state == .done { p.blocks.removeAll { $0.taskID == id && $0.id != block.id && $0.state == .planned } }
        }
        _ = persist(message: completed ? "Complete work block" : "Pause work with resume note", tasks: changed, plan: p) {
            self.applyPlan(p); self.applyTasks(changed)
            if completed, let rid = block.routineID, let r = self.routines.first(where: { $0.id == rid }) { self.celebration = r }
            else { self.showNotice(completed ? "Progress saved. Nicely done." : "Resume note saved. Replan when you’re ready.") }
        }
    }
    @discardableResult func savePlan(_ p: DayPlan, message: String) -> Bool { persist(message: message, plan: p) { self.applyPlan(p) } }
    @discardableResult func savePlans(_ values: [DayPlan], message: String) -> Bool { persist(message: message, plans: values) { for p in values { self.applyPlan(p) } } }
    private func ownerPlan(for block: PlanBlock) -> DayPlan? {
        plans.first { $0.id == (block.calendarOwnerDay ?? dayKey) && $0.blocks.contains(where: { $0.id == block.id }) }
    }
    private func applyPlan(_ p: DayPlan) { plans.removeAll { $0.id == p.id }; plans.append(p) }
    private func applyTasks(_ changed: [PlannerTask]) { for t in changed { if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } } }
    func showNotice(_ value: String) {
        notice = value
        Task { try? await Task.sleep(for: .seconds(3)); if notice == value { notice = nil } }
    }
    private func importMeetingTasks(_ receipt: MeetingTaskImport) -> Bool {
        let existing = Set(tasks.map(\.id))
        let additions = receipt.tasks.filter { !existing.contains($0.id) }
        let captures = (try? repository?.load(Capture.self, directory: "captures")) ?? []
        if additions.isEmpty && captures.contains(where: { $0.id == receipt.capture.id }) { return true }
        return persist(message: "Import reviewed meeting tasks", tasks: additions, captures: captures.contains(where: { $0.id == receipt.capture.id }) ? [] : [receipt.capture]) {
            self.tasks.append(contentsOf: additions)
            for task in additions { self.categorizeInventoryTask(task) }
            self.showNotice("\(receipt.tasks.count) meeting \(receipt.tasks.count == 1 ? "task" : "tasks") added to Inbox")
        }
    }
    @discardableResult func persist(message: String, tasks: [PlannerTask] = [], captures: [Capture] = [], routines: [Routine] = [], completions: [TaskCompletion] = [], calendarEdits: [CalendarBlockEdit] = [], plan: DayPlan? = nil, plans: [DayPlan] = [], deletingTaskIDs: [String] = [], settings: PlanningSettings? = nil, notes: [LibraryNote] = [], attachments: [RepositoryAttachmentWrite] = [], apply: () -> Void) -> Bool {
        guard let repository else { error = "The local workspace is unavailable. Your edit has not been saved."; return false }
        func prepared(_ value: DayPlan) -> DayPlan {
            var p = CalendarSchedule.canonical(value)
            if p != value { p = Scheduler().refreshingLayout(p, settings: self.settings, tasks: self.tasks) }
            if let publication = p.publication { p.publication = publication.invalidatingChanges(in: p, timeZone: self.settings.timeZone) }
            return p
        }
        let savedPlan = plan.map(prepared), savedPlans = plans.map(prepared)
        do {
            try repository.save(tasks: tasks, captures: captures, routines: routines, completions: completions, calendarEdits: calendarEdits, plan: savedPlan, plans: savedPlans, deletingTaskIDs: deletingTaskIDs, settings: settings, notes: notes, attachments: attachments, message: message)
            apply()
            for e in calendarEdits { self.calendarEdits.removeAll { $0.id == e.id }; self.calendarEdits.append(e) }
            for entry in completions { self.completions.removeAll { $0.id == entry.id }; self.completions.append(entry) }
            if let savedPlan { applyPlan(savedPlan) }; for p in savedPlans { applyPlan(p) }
            savedAt = Date(); library.scheduleBackup(); return true
        }
        catch { self.error = error.localizedDescription; return false }
    }
    private func loadDemo() {
        now = PlannerDate.at(8 * 60 + 55, on: Date(), settings: settings)
        let a = PlannerTask(id: "demo-proposal", title: "Shape the Rogers solution proposal", context: "T1A · Presales", tags: ["Rogers"], state: .ready, importance: true, urgency: true, remainingMinutes: 60)
        let b = PlannerTask(id: "demo-8fde", title: "Map the next 8FDE product milestone", context: "T1A · Product", tags: ["8FDE"], state: .ready, importance: true, urgency: false, remainingMinutes: 90)
        let c = PlannerTask(id: "demo-notes", title: "Turn discovery notes into next steps", context: "T1A · Delivery", tags: ["Rogers"], state: .ready, importance: true, urgency: false, remainingMinutes: 30)
        var d = PlannerTask(id: "demo-admin", title: "Clear the small follow-ups", context: "Admin", state: .ready, importance: false, urgency: true, remainingMinutes: 15)
        d.minimumBlockMinutes = 15
        tasks = [a, b, c, d, PlannerTask(title: "Look into a simpler proposal handoff", context: "T1A")]
        if CommandLine.arguments.contains("--matrix-demo") {
            let projects = ["Rogers", "8FDE", "Wells"]
            for quadrant in Quadrant.allCases {
                for index in 1...12 {
                    let project = projects[(index - 1) % projects.count]
                    let title = index == 3 ? "Review the detailed implementation approach and confirm the delivery milestones with the project team" : "\(project) · Review delivery item \(index)"
                    var task = PlannerTask(id: "matrix-\(quadrant.rawValue)-\(index)", title: title, context: "T1A · Delivery", tags: [project],
                        state: index == 2 ? .waiting : .ready, importance: quadrant == .doFirst || quadrant == .schedule,
                        urgency: quadrant == .doFirst || quadrant == .delegate, remainingMinutes: 30,
                        now: now.addingTimeInterval(Double(index)))
                    if index == 3 { task.tags.append("Release planning") }
                    tasks.append(task)
                }
            }
        }
        routines = Routine.defaults.map { var r = $0; r.enabled = true; return r }
        let meeting = PlanBlock(id: "demo-meeting", title: "Architecture working session", context: "Example meeting", kind: .meeting, start: PlannerDate.at(660, on: now, settings: settings), end: PlannerDate.at(705, on: now, settings: settings), pinned: true)
        plans = [Scheduler().makePlan(day: now, now: now, tasks: tasks, routines: routines, settings: settings, meetings: [meeting], outcomeIDs: [a.id, b.id])]
        if CommandLine.arguments.contains("--calendar-sync-demo") {
            var p = Scheduler().makePlan(day: now, now: now, tasks: [b, c], routines: routines, settings: settings, meetings: [meeting])
            let ids = p.blocks.filter { $0.taskID == b.id || $0.routineID != nil }.map(\.id)
            p.publication = CalendarPublication(plan: p, workspaceID: workspaceID,
                destination: PublicationDestination(id: "example", title: "Example calendar", accountID: "example"), timeZone: settings.timeZone, confirmedBlockIDs: ids)
            p.publication!.state = .published; p.publication!.known = p.publication!.desired; p.status = .local
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
            var minute = 540
            let times = p.publication!.desired.sorted { $0.start < $1.start }.map { event in
                let start = PlannerDate.at(minute, on: tomorrow, settings: settings)
                minute += Int(event.end.timeIntervalSince(event.start) / 60) + 10
                return CalendarEventTime(id: event.id, start: start, end: start.addingTimeInterval(event.end.timeIntervalSince(event.start)))
            }
            plans = [CalendarSchedule.reconciling(p, times: times, settings: settings).plan]
            tasks.append(PlannerTask(id: "demo-unscheduled", title: "Review next month’s priorities", tags: ["8FDE"], state: .ready, importance: true, urgency: false, remainingMinutes: 25))
            let pending = PlannerTask(id: "demo-pending", title: "Prepare partner briefing", tags: ["Rogers"], state: .ready, importance: true, urgency: false, remainingMinutes: 25)
            tasks.append(pending)
            let later = calendar.date(byAdding: .day, value: 2, to: now)!
            var q = Scheduler().makePlan(day: later, now: now, tasks: [pending], routines: [], settings: settings)
            q.publication = CalendarPublication(plan: q, workspaceID: workspaceID, destination: p.publication!.destination, timeZone: settings.timeZone)
            plans.append(q)
        }
        if CommandLine.arguments.contains("--completion-demo") {
            tasks = Quadrant.allCases.map { q in
                PlannerTask(id: "completion-demo-q\(q.rawValue)", title: "Q\(q.rawValue) · Finish the proposal planned for tomorrow", context: "T1A · Example", tags: ["8FDE"], state: .ready, importance: q == .doFirst || q == .schedule, urgency: q == .doFirst || q == .delegate, remainingMinutes: 30, now: now)
            }
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
            var future = Scheduler().makePlan(day: tomorrow, now: now, tasks: tasks, routines: [], settings: settings)
            future.publication = CalendarPublication(plan: future, workspaceID: workspaceID, destination: PublicationDestination(id: "example", title: "Example calendar", accountID: "example"), timeZone: settings.timeZone)
            future.publication!.state = .published; future.publication!.known = future.publication!.desired
            plans = [future]; selectedDay = tomorrow
            let earlier = TaskLifecycle.change(PlannerTask(id: "completion-demo-earlier", title: "Prepare the earlier product brief", tags: ["8FDE"], state: .ready, importance: true, urgency: false, remainingMinutes: 25), to: .complete, plans: [], now: now.addingTimeInterval(-86400))
            tasks.append(earlier.task!); completions = earlier.completions
            do { try repository?.save(tasks: tasks, completions: completions, plans: plans, message: "Initialize isolated completion example") } catch { self.error = error.localizedDescription }
            page = .matrix
        }
    }
}

private enum PlanningReadError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let message): return message } }
}

struct PriorityReviewRequest: Identifiable {
    var id: String { task.id }
    let task: PlannerTask
    let originalRevision: Int
    var inboxItem: InboxItem? = nil
}
