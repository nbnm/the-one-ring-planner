import Foundation
import RingCore

// Explicitly opt-in, fictional documentation fixtures. PlannerStore calls this only in --demo.
extension PlannerStore {
    func loadMiddleEarthDemo() {
        now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 8, minute: 55))!
        selectedDay = now
        settings.lunchMinutes = 50
        func task(_ id: String, _ title: String, _ tag: String, _ q: Quadrant, _ minutes: Int) -> PlannerTask {
            var value = PlannerTask(id: "shire-" + id, title: title, context: "Fellowship · Fictional example", tags: [tag], state: .ready,
                importance: q == .doFirst || q == .schedule, urgency: q == .doFirst || q == .delegate, remainingMinutes: minutes, now: now)
            value.minimumBlockMinutes = min(25, minutes)
            return value
        }
        tasks = [
            task("ferry", "Secure the Bucklebury ferry", "The Shire", .doFirst, 30),
            task("lembas", "Pack lembas for the journey", "Fellowship", .doFirst, 45),
            task("pony", "Find Bill the pony before departure", "Bree", .doFirst, 25),
            task("map", "Map a quieter route to Rivendell", "Fellowship", .schedule, 90),
            task("elvish", "Practice Elvish with Bilbo", "Rivendell", .schedule, 45),
            task("garden", "Plan next spring’s Bag End garden", "The Shire", .schedule, 60),
            task("invitations", "Ask Merry to deliver party invitations", "The Shire", .delegate, 20),
            task("supplies", "Send Sam the market list", "Fellowship", .delegate, 15),
            task("fireworks", "Confirm Gandalf’s fireworks delivery", "The Shire", .delegate, 25),
            task("spoons", "Count the silver spoons again", "Bag End", .reconsider, 15),
            task("pipeweed", "Rank every pipe-weed in the Southfarthing", "The Shire", .reconsider, 45),
            task("riddles", "Organize the riddle collection by difficulty", "Bag End", .reconsider, 30),
            PlannerTask(id: "shire-inbox-1", title: "Ask the eagles about return flights", tags: ["Fellowship"], now: now),
            PlannerTask(id: "shire-inbox-2", title: "Try Sam’s new potato recipe", tags: ["The Shire"], now: now),
            PlannerTask(id: "shire-inbox-3", title: "Return Bilbo’s borrowed walking map", tags: ["Rivendell"], now: now)
        ]
        routines = [
            Routine(id: "shire-breakfast", title: "Second breakfast", minutes: 20, startMinute: 630, endMinute: 660, protected: true, enabled: true),
            Routine(id: "shire-walk", title: "Walk through the Shire", kind: .movement, minutes: 30, startMinute: 900, endMinute: 960, enabled: true),
            Routine(id: "shire-song", title: "An evening song at Bag End", kind: .guitar, minutes: 15, startMinute: 975, endMinute: 1020, enabled: true),
            Routine(id: "shire-review", title: "Write a page in the Red Book", kind: .review, minutes: 15, startMinute: 990, endMinute: 1020, protected: true, enabled: true)
        ]
        plans = []; calendarGridDemoEvents = []
        let days = CalendarGrid.days(containing: now, week: true, calendar: calendar)
        for (index, day) in days.enumerated() where index < 5 {
            let prefix = "shire-day-\(index)"
            let morning = tasks[index % 3], afternoon = tasks[3 + index % 3]
            let blocks = [
                PlanBlock(id: prefix + "-morning", title: morning.title, kind: .focus, start: PlannerDate.at(540, on: day, settings: settings), end: PlannerDate.at(540 + (morning.remainingMinutes ?? 30), on: day, settings: settings), taskID: morning.id),
                PlanBlock(id: prefix + "-breakfast", title: routines[0].title, kind: .routine, start: PlannerDate.at(630, on: day, settings: settings), end: PlannerDate.at(650, on: day, settings: settings), routineID: routines[0].id),
                PlanBlock(id: prefix + "-council", title: index == 3 ? "Council of Elrond" : "Fellowship route check-in", context: "Fictional meeting", kind: .meeting, start: PlannerDate.at(660, on: day, settings: settings), end: PlannerDate.at(index == 3 ? 710 : 690, on: day, settings: settings), pinned: true),
                PlanBlock(id: prefix + "-lunch", title: "Lunch at the Green Dragon", kind: .lunch, start: PlannerDate.at(720, on: day, settings: settings), end: PlannerDate.at(770, on: day, settings: settings)),
                PlanBlock(id: prefix + "-afternoon", title: afternoon.title, kind: .focus, start: PlannerDate.at(780, on: day, settings: settings), end: PlannerDate.at(780 + (afternoon.remainingMinutes ?? 60), on: day, settings: settings), taskID: afternoon.id),
                PlanBlock(id: prefix + "-walk", title: routines[1].title, kind: .routine, start: PlannerDate.at(900, on: day, settings: settings), end: PlannerDate.at(930, on: day, settings: settings), routineID: routines[1].id),
                PlanBlock(id: prefix + "-review", title: routines[3].title, kind: .routine, start: PlannerDate.at(990, on: day, settings: settings), end: PlannerDate.at(1005, on: day, settings: settings), routineID: routines[3].id)
            ]
            var plan = Scheduler().makePlan(day: day, now: now, tasks: [], routines: [], settings: settings)
            plan.blocks = blocks; plan.outcomeIDs = [morning.id, afternoon.id]
            plans.append(plan)
            if let council = blocks.first(where: { $0.kind == .meeting }) {
                calendarGridDemoEvents.append(CalendarOccurrence(id: council.id, calendarID: "shire-example", title: council.title,
                    calendarTitle: "Fellowship · Fictional calendar", start: council.start, end: council.end))
            }
        }
        page = .today
    }
}

extension MeetingStore {
    func middleEarthMeeting(_ original: MeetingRecording) -> MeetingRecording {
        var record = original
        record.title = "Council of Elrond · Journey planning"
        record.source = .systemAndMicrophone
        let lines = [
            "I’ll map a quieter route to Rivendell and pack enough lembas for the road.",
            "Я проверю припасы и подготовлю список вещей для нашего путешествия.",
            "Let’s leave room for second breakfast. Sam can take care of the garden while we are away.",
            "Обсудим маршрут через Шир и сделаем остановку у Зелёного Дракона.",
            "We still need someone to ask the eagles about the journey home.",
            "Договорились. Встретимся у Бэг-Энда утром и проверим карту вместе."
        ]
        for index in record.segments.indices { record.segments[index].text = lines[index] }
        record.speakerNames = [:]
        record.speakerAliases = [.init(id: MeetingSpeakerAlias.myselfID, name: "Frodo"), .init(id: "samwise", name: "Samwise")]
        record.speakerAliasAssignments = ["part-001:A": MeetingSpeakerAlias.myselfID, "part-001:B": "samwise"]
        record.topics = [
            .init(title: "A road to Rivendell", summary: "Route planning and travel supplies.", evidenceIDs: ["example1", "example2"]),
            .init(title: "Second breakfast & Shire stops", summary: "Leave room for the important things.", evidenceIDs: ["example3", "example4"]),
            .init(title: "The journey home", summary: "Eagles, maps and the morning rendezvous.", evidenceIDs: ["example5", "example6"])
        ]
        record.summaries = ["The Fellowship agreed on a quieter route, a supply check, and a morning meeting at Bag End. Second breakfast remains protected."]
        record.suggestions = [
            .init(title: "Map a quieter route to Rivendell", tags: ["Fellowship"], speakerID: "part-001:A", timing: "Before departure", evidenceIDs: ["example1"]),
            .init(title: "Ask the eagles about return flights", tags: ["Fellowship"], evidenceIDs: ["example5"]),
            .init(title: "Проверить припасы для путешествия", tags: ["The Shire"], speakerID: "part-001:B", evidenceIDs: ["example2"])
        ]
        return record
    }
}
