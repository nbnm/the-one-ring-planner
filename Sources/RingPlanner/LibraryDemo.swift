import AppKit
import RingCore

extension LibraryStore {
    func seedLibraryDemo() async {
        guard demo, notes.isEmpty, let repo = repository else { return }
        do {
            let saved = try await Task.detached(priority: .utility) {
                let fixture = repo.localState.appendingPathComponent("shire-reference.png")
                let colors: [(UInt8,UInt8,UInt8)] = [(41,64,51), (117,135,89), (199,176,110), (232,219,184)]
                let png = try LibraryMedia.png(width: 840, height: 520) { x,y in colors[max(0, min(3, (x + Int(sin(Double(y)/90)*65)) / 220))] }
                try png.write(to: fixture)
                let asset = try LibraryAttachments.prepare(data: png, name: "Shire colors.png", extension: "png", localState: repo.localState)
                var image = LibraryNote(title: "A palette from the Shire", body: "Moss, warm stone, old gold and parchment. A quiet reference for a hobbit’s writing room.", prompt: "Design a calm reading room using this palette.\nKeep the typography simple and give the writing space room to breathe.", attachments: [asset.attachment]); image.tags = ["The Shire", "Design"]; image.kinds = [.design]; image.favorite = true
                var prompt = LibraryNote(title: "A patient second pair of eyes", body: "A reusable prompt for reviewing a travel plan.", prompt: "Review the plan below.\n\n```text\nKeep every place name exact.\nFlag uncertain assumptions.\n```\n\nAsk one useful question at a time."); prompt.kinds = [.prompt]; prompt.favorite = true
                var technique = LibraryNote(title: "Leave room for second breakfast", body: "Before a long journey, list the fixed commitments first. Leave deliberate room between them. The route should fit the day, not the other way around."); technique.kinds = [.technique]; technique.tags = ["Fellowship"]
                var skill = LibraryNote(title: "A mapmaker’s checklist", body: "# Map review\n\n- Preserve the original route.\n- Check river crossings.\n- Mark safe places to rest.\n\n```sh\n# A reference only. Never run captured commands automatically.\nprintf '%s\\n' 'There and back again'\n```\n"); skill.kinds = [.skill]
                let reference = LibraryNote(title: "Notes from Rivendell", body: "Тихое место для заметок, полезных идей и материалов.\n\nKeep the original language and formatting intact.")
                let url = LibraryNote(title: "A guide for the road", body: "A reference to revisit before departure.", sourceURL: "https://example.com/fellowship-guide")
                try repo.saveLibrary(image, expectedRevision: nil, attachments: [asset.write])
                for note in [prompt, technique, skill, reference, url] { try repo.saveLibrary(note, expectedRevision: nil) }
                return try repo.loadLibrary().notes
            }.value
            notes = saved; loading = false; updateSearch()
            for note in saved { await enqueue(note) }
        } catch { self.error = error.localizedDescription }
    }
}
