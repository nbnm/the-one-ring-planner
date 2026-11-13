import SwiftUI
import RingCore

struct LibraryFolderPicker: View {
    let folders: [String]
    @Binding var folder: String?
    var allowAll = false
    var body: some View {
        Picker("Folder", selection: $folder) {
            if allowAll { Text("All folders").tag(nil as String?) }
            Text("Unfiled").tag(allowAll ? "" as String? : nil as String?)
            ForEach(folders, id: \.self) { Text($0).tag($0 as String?) }
        }.accessibilityLabel("Library folder")
    }
}
struct LibraryFolderControls: View {
    @ObservedObject var library: LibraryStore
    @State private var editing = false
    @State private var renaming = false
    @State private var name = ""
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(Theme.gold)
            LibraryFolderPicker(folders: library.folders, folder: $library.folder, allowAll: true).labelsHidden().frame(maxWidth: 230)
            Menu {
                Button("New folder…") { name = ""; renaming = false; editing = true }
                if let folder = library.folder, !folder.isEmpty {
                    Button("Rename folder…") { name = folder; renaming = true; editing = true }
                }
                Button("Show folder in Finder") { library.revealFolder() }
            } label: { Image(systemName: "folder.badge.gearshape") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Library folder actions")
        }.sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 18) {
                Text(renaming ? "Rename folder" : "New folder").font(Theme.display(26))
                TextField("Folder name, e.g. Home/Ideas", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Library folder name")
                Text("Folders are saved inside your local notes directory.").font(Theme.body(11)).foregroundStyle(Theme.secondary)
                if let error = library.error { Text(error).foregroundStyle(Theme.alert).font(Theme.body(11)) }
                HStack { Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction); Spacer(); Button("Save folder") { Task { if await library.saveFolder(name, renaming: renaming ? library.folder : nil) { editing = false } } }.buttonStyle(GoldButton()).disabled(library.saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
            }.padding(26).frame(width: 420).background(Theme.background).foregroundStyle(Theme.text)
        }
    }
}
extension LibraryStore {
    func saveFolder(_ input: String, renaming old: String?) async -> Bool {
        guard !saving, let repository else { return false }
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        saving = true; error = nil; defer { saving = false }
        do {
            try await Task.detached {
                if let old { try repository.renameLibraryFolder(old, to: path) }
                else { try repository.createLibraryFolder(path) }
            }.value
            await reload(); folder = path; scheduleBackup(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func revealFolder() {
        guard let repository else { return }
        let url = repository.root.appendingPathComponent("notes").appendingPathComponent(folder ?? "")
        do { _ = try repository.validatedURL("notes/" + ((folder?.isEmpty == false) ? folder! + "/" : "") + "00000000-0000-0000-0000-000000000000.json"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) }
        catch { self.error = error.localizedDescription }
    }
}
