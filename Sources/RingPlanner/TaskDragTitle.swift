import SwiftUI
import AppKit
import RingCore

struct TaskDragSession {
    let taskID: String
    let title: String
    var location: CGPoint
}

enum PlannerDragSpace {
    static let workspace = "planner-workspace"
}

struct PriorityDropRegionsKey: PreferenceKey {
    static let defaultValue: [Quadrant: CGRect] = [:]
    static func reduce(value: inout [Quadrant: CGRect], nextValue: () -> [Quadrant: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Local pointer tracking keeps moves inside the planner, without an OS pasteboard session.
struct TaskDragTitle: View {
    @EnvironmentObject var store: PlannerStore
    let taskID: String
    let title: String
    var fontSize: CGFloat = 12
    var lineSpacing: CGFloat = 0
    var lineLimit: Int? = nil
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .frame(width: 16, height: 20)
            Text(title).font(Theme.body(fontSize, weight: .semibold))
                .lineLimit(lineLimit)
                .lineSpacing(lineSpacing).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
        }
        .accessibilityHidden(true)
        .overlay {
            TaskDragSurface(title: title, open: open,
                move: { store.updateTaskDrag(taskID: taskID, title: title, location: $0) },
                finish: { store.finishTaskDrag(taskID: taskID, location: $0) },
                cancel: { store.taskDrag = nil })
        }
    }
}

private struct TaskDragSurface: NSViewRepresentable {
    let title: String
    let open: () -> Void
    let move: (CGPoint) -> Void
    let finish: (CGPoint) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.open = open; view.move = move; view.finish = finish; view.cancel = cancel
        view.setAccessibilityLabel(title)
        view.setAccessibilityHelp("Drag this title or grip to a priority quadrant. Activate to edit.")
        view.toolTip = "Drag this title or grip to a quadrant. Click to edit."
    }

    final class DragView: NSView {
        var open: () -> Void = {}
        var move: (CGPoint) -> Void = { _ in }
        var finish: (CGPoint) -> Void = { _ in }
        var cancel: () -> Void = {}
        private var pressOrigin: NSPoint?
        private var didDrag = false
        private var cancelled = false
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true); setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { fatalError("Not used") }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func accessibilityPerformPress() -> Bool { open(); return true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancelled = true; cancel() }
            else if event.keyCode == 36 || event.keyCode == 49 { open() }
            else { super.keyDown(with: event) }
        }
        override func mouseDown(with event: NSEvent) {
            pressOrigin = event.locationInWindow; didDrag = false; cancelled = false
            window?.makeFirstResponder(self)
        }
        private func workspacePoint(_ event: NSEvent) -> CGPoint? {
            guard let root = window?.contentView else { return nil }
            let point = root.convert(event.locationInWindow, from: nil)
            return CGPoint(x: point.x, y: root.isFlipped ? point.y : root.bounds.height - point.y)
        }
        override func mouseDragged(with event: NSEvent) {
            guard !cancelled, let origin = pressOrigin,
                  hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4,
                  let point = workspacePoint(event) else { return }
            didDrag = true
            move(point)
        }
        override func mouseUp(with event: NSEvent) {
            defer { pressOrigin = nil; didDrag = false }
            guard !cancelled else { return }
            if didDrag, let point = workspacePoint(event) { finish(point) }
            else if bounds.contains(convert(event.locationInWindow, from: nil)) { open() }
        }
    }
}

struct TaskDragPreview: View {
    let drag: TaskDragSession
    var body: some View {
        GeometryReader { geometry in
            Label(drag.title, systemImage: "line.3.horizontal")
                .font(Theme.body(12, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(1).padding(12).frame(width: 250, height: 44, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.gold))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .offset(x: max(0, min(drag.location.x + 14, geometry.size.width - 250)),
                        y: max(0, min(drag.location.y - 22, geometry.size.height - 44)))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
