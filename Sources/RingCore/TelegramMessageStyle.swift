import Foundation

/// Presentation is applied at delivery, so queued captures/commands retain their original plain text.
public enum TelegramMessageStyle {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    public static func html(_ source: String) -> String {
        var plain = "", units = 0
        for character in source {
            let size = String(character).utf16.count
            if units + size > 3800 { plain += "\n…"; break }
            plain.append(character); units += size
        }
        let lines = plain.components(separatedBy: "\n")
        let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? 0
        let commands = lines[first].hasPrefix("/today") && plain.contains("/tasks") && plain.contains("/help") == false
        var result: [String] = commands ? ["🧭 <b>Commands</b>", ""] : []
        var taskTitle = false
        for (index, line) in lines.enumerated() {
            if !commands && index == first {
                if line.hasPrefix("Saved to Inbox · ") {
                    result.append("📥 <b>Saved to Inbox</b>\n" + escape(String(line.dropFirst("Saved to Inbox · ".count))))
                } else { result.append(icon(for: line) + " <b>" + escape(line) + "</b>") }
                continue
            }
            if taskTitle, !line.isEmpty { result.append("<b>" + escape(line) + "</b>"); taskTitle = false; continue }
            if line.range(of: "^[0-9a-fA-F]{8} · (Q[1-4]|Inbox) · ", options: .regularExpression) != nil {
                result.append("<code>" + escape(String(line.prefix(8))) + "</code>" + escape(String(line.dropFirst(8))))
                taskTitle = true
            } else if let range = line.range(of: "^(?:✓ )?[0-9]{2}:[0-9]{2}[–-][0-9]{2}:[0-9]{2}", options: .regularExpression) {
                result.append("<b>" + escape(String(line[range])) + "</b>" + escape(String(line[range.upperBound...])))
            } else if line.hasPrefix("/"), let divider = line.range(of: " · ") {
                result.append("<code>" + escape(String(line[..<divider.lowerBound])) + "</code>" + escape(String(line[divider.lowerBound...])))
            } else { result.append(escape(line)) }
        }
        return result.joined(separator: "\n")
    }
    private static func icon(for heading: String) -> String {
        if heading.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2} · ", options: .regularExpression) != nil || heading.hasPrefix("Preview ·") { return "📅" }
        if heading.hasPrefix("Work tasks") { return "💼" }
        if heading.hasPrefix("Personal tasks") { return "🏡" }
        if heading.hasPrefix("Active tasks") { return "📋" }
        if heading.hasPrefix("Inbox") || heading.hasPrefix("Saved to Inbox") { return "📥" }
        if heading.hasPrefix("Audio saved") || heading.hasPrefix("Transcribed") { return "🎙" }
        if heading.hasPrefix("Paired") || heading.hasPrefix("Connected") { return "🔐" }
        if heading.hasPrefix("In 1 minute") { return "⏰" }
        if heading.hasPrefix("Q1 ·") { return "⚡️" }
        if heading.hasPrefix("This capture needs") || heading.hasPrefix("Unknown command") { return "⚠️" }
        return "💍"
    }
    public static let preview = """
    Preview · today's plan

    09:00–09:30 · Review the map to Rivendell
    09:30–09:45 · Prepare second breakfast

    Active tasks
    a1b2c3d4 · Q2 · Personal
    Pack provisions for the journey

    /today · today's plan
    /tasks · active tasks
    /inbox · captured thoughts
    """
}
