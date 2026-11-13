import Foundation

public enum TelegramIdentity {
    public static let name = "The One Ring Planner"
    public static func shortDescription(language: String = "") -> String {
        language == "ru" ? "Личный спутник для задач, заметок и повседневных приключений." : "Your private companion for tasks, notes and daily quests."
    }
    public static func description(language: String = "") -> String {
        language == "ru"
            ? "Спокойный спутник для повседневных приключений.\n\nОтправляйте мысли, ссылки, изображения и голосовые заметки в The One Ring Planner. Смотрите план дня, находите следующую задачу и разделяйте рабочие и личные дела.\n\nДоступ только у привязанного владельца. /help"
            : "A quiet companion for your daily quest.\n\nSend thoughts, links, images or voice notes to The One Ring Planner. Check today's plan, find the next task, and keep work and personal quests in order.\n\nPrivate access is limited to the paired owner. /help"
    }
}
public struct TelegramIdentityResult: Sendable {
    public let name: String
    public let shortDescription: String
    public let description: String
    public let photoFileID: String
}
