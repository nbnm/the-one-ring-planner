import SwiftUI
import RingCore

struct TagFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(width: proposal.width ?? 400, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() { subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified) }
    }
    private func layout(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []; var x: CGFloat = 0; var y: CGFloat = 0; var row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; row = max(row, size.height)
        }
        return (CGSize(width: width, height: subviews.isEmpty ? 0 : y + row), points)
    }
}

struct TaskTagsView: View {
    let tags: [String]
    var body: some View {
        if !tags.isEmpty {
            TagFlow {
                ForEach(tags, id: \.self) { tag in
                    Label(tag, systemImage: "number").font(Theme.body(10, weight: .medium)).foregroundStyle(Theme.gold)
                        .padding(.horizontal, 7).padding(.vertical, 4).background(Theme.goldFill, in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel("Tag: \(tag)")
                }
            }
        }
    }
}

struct TaskTagEditor: View {
    @Binding var tags: [String]
    let knownTags: [String]
    @State private var entry = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                TagFlow {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 5) {
                            Text(tag)
                            Button { tags.removeAll { $0 == tag } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }.buttonStyle(.plain).accessibilityLabel("Remove tag \(tag)")
                        }.font(Theme.body(11)).foregroundStyle(Theme.gold).padding(.horizontal, 8).padding(.vertical, 5).background(Theme.goldFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Project / topic tag", text: $entry).textFieldStyle(.roundedBorder).onSubmit(add).accessibilityLabel("New project or topic tag")
                Button(action: add) { Image(systemName: "plus") }.buttonStyle(.plain).disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.count > 60).accessibilityLabel("Add project or topic tag")
                if !knownTags.isEmpty {
                    Menu("Existing tags") { ForEach(knownTags.filter { !tags.contains($0) }, id: \.self) { tag in Button(tag) { tags = TaskTags.normalize(tags + [tag], known: knownTags) } } }.fixedSize().font(Theme.body(11))
                }
            }
            Text("First tag groups this task. Add a tag with Return or +.").font(Theme.body(10)).foregroundStyle(Theme.secondary)
        }
    }
    private func add() {
        guard entry.count <= 60 else { return }
        tags = TaskTags.normalize(tags + entry.split(separator: ",").map(String.init), known: knownTags); entry = ""
    }
}

struct TaskTagControls: View {
    let tags: [String]
    @Binding var filter: TaskTagFilter
    @Binding var grouped: Bool
    var body: some View {
        HStack(spacing: 10) {
            Picker("Filter tasks by tag", selection: $filter) {
                Text("All tasks").tag(TaskTagFilter.all)
                Text("Work").tag(TaskTagFilter.tag("Work"))
                Text("Personal").tag(TaskTagFilter.tag("Personal"))
                Text("Untagged").tag(TaskTagFilter.untagged)
                ForEach(tags.filter { TaskArea.from([$0]) == nil }, id: \.self) { Text($0).tag(TaskTagFilter.tag($0)) }
            }.labelsHidden().frame(maxWidth: 180).accessibilityLabel("Filter tasks by tag")
            Spacer(minLength: 0)
            Toggle(isOn: $grouped) { Image(systemName: "rectangle.3.group").font(.system(size: 12)) }.toggleStyle(.button)
                .help("Group by first project or topic tag").accessibilityLabel("Group tasks by tag")
        }.font(Theme.body(11))
            .onChange(of: tags) { _, values in
                if case .tag(let name) = filter, TaskArea.from([name]) == nil, !values.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { filter = .all }
            }
    }
}

struct TagGroupHeading: View {
    let group: TaskTagGroup
    var body: some View {
        if let title = group.title {
            HStack { Text(title).font(Theme.body(11, weight: .semibold)); Spacer(); Text("\(group.tasks.count)").font(Theme.body(10)).monospacedDigit() }.foregroundStyle(Theme.secondary).padding(.top, 16).padding(.bottom, 4)
        }
    }
}

struct TaskAreaPicker: View {
    @Binding var tags: [String]
    var body: some View {
        Picker("Schedule", selection: Binding(get: { TaskArea.from(tags) ?? .work }, set: { tags = $0.applying(to: tags) })) {
            ForEach(TaskArea.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).accessibilityLabel("Work or Personal task")
    }
}
