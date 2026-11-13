import Foundation

public enum TelegramCommands {
    public static let help = "/today · today's plan\n/tomorrow · tomorrow's plan\n/next · next task\n/tasks [page] · active tasks\n/work [page] · work tasks\n/personal [page] · personal tasks\n/task ID · details\n/find words · search tasks\n/inbox [page] · Inbox\n/status · polling and pending captures\n\nSend text, links, images, files or voice notes to capture them."
    public static func reply(_ text: String, tasks: [PlannerTask], plans: [DayPlan], inbox: [InboxItem], settings: PlanningSettings, now: Date) -> String {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let name = (parts.first ?? "").split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        let args = Array(parts.dropFirst())
        switch name {
        case "/help", "/start", "/pair": return help
        case "/today": return plan(now, plans: plans, tasks: tasks, settings: settings, now: now)
        case "/tomorrow": return plan(PlannerDate.calendar(settings).date(byAdding: .day, value: 1, to: now)!, plans: plans, tasks: tasks, settings: settings, now: now)
        case "/tasks", "/work", "/personal", "/find":
            let area: TaskArea? = name == "/work" ? .work : name == "/personal" ? .personal : nil
            let query = name == "/find" ? args.joined(separator: " ") : ""
            if name == "/find", query.isEmpty { return "Use /find followed by words from a task or tag." }
            let page = max(1, min(10000, Int(args.first ?? "") ?? 1))
            let matches = tasks.filter { $0.state != .done && $0.state != .archived && (area == nil || $0.area == area) && (query.isEmpty || [$0.title, $0.notes, $0.tags.joined(separator: " ")].joined(separator: " ").localizedCaseInsensitiveContains(query)) }.sorted(by: order)
            guard !matches.isEmpty else { return "No matching active tasks." }
            let actualPage = name == "/find" ? 1 : min(page, (matches.count + 9) / 10)
            let rows = matches.dropFirst((actualPage - 1) * 10).prefix(10).map { "\($0.id.prefix(8)) · \($0.quadrant.map { "Q\($0.rawValue)" } ?? "Inbox") · \($0.area.rawValue)\n\($0.title)" }
            return bounded("\(area?.rawValue ?? "Active") tasks · \(matches.count)\n\n" + rows.joined(separator: "\n\n") + (matches.count > 10 ? "\n\nPage \(actualPage)/\((matches.count + 9) / 10) · \(name == "/find" ? "/tasks" : name) \(actualPage + 1)" : "") + "\n/task ID for details")
        case "/task":
            guard let id = args.first, id.count >= 4 else { return "Use /task followed by the ID shown by /tasks." }
            let matches = tasks.filter { $0.id.lowercased().hasPrefix(id.lowercased()) }
            guard matches.count == 1, let task = matches.first else { return matches.isEmpty ? "Task not found." : "That ID matches several tasks. Use a longer ID." }
            let entries = TaskScheduleEntry.entries(taskID: task.id, plans: plans, now: now)
            var lines = [task.title, "\(task.area.rawValue) · \(task.state.rawValue) · \(task.quadrant.map { "Q\($0.rawValue)" } ?? "Inbox")"]
            if let minutes = task.remainingMinutes { lines.append("Remaining: \(minutes) min") }
            if !task.tags.isEmpty { lines.append(task.tags.joined(separator: " · ")) }
            for entry in entries.prefix(5) { lines.append("\(entry.status.rawValue): \(stamp(entry.start, settings: settings)) · \(entry.minutes) min") }
            if let completed = task.completedAt { lines.append("Completed: \(stamp(completed, settings: settings))") }
            if !task.notes.isEmpty { lines.append(task.notes) }
            return bounded(lines.joined(separator: "\n\n"))
        case "/next":
            let blocks = plans.flatMap(\.blocks).filter { $0.kind == .focus && ($0.state == .planned || $0.state == .running) && $0.end > now && $0.taskID.map { id in tasks.contains { $0.id == id && $0.isEligible } } == true }.sorted { $0.start < $1.start }
            if let next = blocks.first { return "\(next.title)\n\(stamp(next.start, settings: settings)) · \(next.minutes) min\n/task \((next.taskID ?? "").prefix(8))" }
            guard let next = tasks.filter({ $0.isEligible && $0.quadrant != .reconsider }).sorted(by: order).first else { return "No ready tasks." }
            return "\(next.title)\n\(next.area.rawValue) · Q\(next.quadrant!.rawValue) · not scheduled\n/task \(next.id.prefix(8))"
        case "/inbox":
            let items = inbox.filter(\.active).sorted { $0.createdAt < $1.createdAt }
            let legacy = tasks.filter { $0.state == .inbox }.map { "\($0.id.prefix(8)) · \($0.title)" }
            let rows = items.map { "\($0.id.prefix(8)) · \($0.title)" } + legacy
            guard !rows.isEmpty else { return "Inbox is empty." }
            let page = max(1, min((rows.count + 9) / 10, Int(args.first ?? "") ?? 1))
            return bounded("Inbox · \(rows.count)\n\n" + rows.dropFirst((page - 1) * 10).prefix(10).joined(separator: "\n\n") + (rows.count > 10 ? "\n\nPage \(page)/\((rows.count + 9) / 10) · /inbox \(page + 1)" : ""))
        default: return "Unknown command. /help lists available commands."
        }
    }
    public static func plan(_ day: Date, plans: [DayPlan], tasks: [PlannerTask], settings: PlanningSettings, now: Date) -> String {
        let key = PlannerDate.key(day, settings: settings)
        guard let plan = CalendarSchedule.plan(on: day, plans: plans, settings: settings, now: now, forDisplay: true, tasks: tasks) else { return "\(key) · no plan yet.\n/next for a ready task." }
        let blocks = plan.blocks.filter { $0.kind != .transition && $0.state != .skipped && $0.state != .interrupted }.sorted { $0.start < $1.start }
        let format = DateFormatter(); format.timeZone = PlannerDate.calendar(settings).timeZone; format.dateFormat = "HH:mm"
        let rows = blocks.prefix(35).map { block in "\(block.state == .completed ? "✓ " : "")\(format.string(from: block.start))–\(format.string(from: block.end)) · \(block.title)" }
        return bounded("\(key) · \(plan.status == .draft ? "Draft" : "Plan")\n\n" + (rows.isEmpty ? "No scheduled activities." : rows.joined(separator: "\n")))
    }
    private static func order(_ a: PlannerTask, _ b: PlannerTask) -> Bool {
        if a.quadrant != b.quadrant { return (a.quadrant?.rawValue ?? 0) < (b.quadrant?.rawValue ?? 0) }
        if a.deadline != b.deadline { return (a.deadline ?? .distantFuture) < (b.deadline ?? .distantFuture) }
        return a.id < b.id
    }
    private static func stamp(_ date: Date, settings: PlanningSettings) -> String { let f = DateFormatter(); f.timeZone = PlannerDate.calendar(settings).timeZone; f.dateFormat = "EEE, MMM d · HH:mm"; return f.string(from: date) }
    private static func bounded(_ text: String) -> String { text.count > 3900 ? String(text.prefix(3850)) + "\n… More details are available in the app." : text }
}
