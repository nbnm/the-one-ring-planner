import SwiftUI
import AppKit
import RingCore

struct CalendarDayFramesKey: PreferenceKey {
    static let defaultValue: [Date: CGRect] = [:]
    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, b in b }) }
}
struct CalendarViewportKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}
@MainActor final class CalendarDragInteraction: ObservableObject {
    struct Preview { let event: CalendarGridEvent; let interval: DateInterval }
    @Published var preview: Preview?
    var frames: [Date: CGRect] = [:]
    var viewport = CGRect.zero
    var startHour = 0
    var scale: CGFloat = 1
    var calendar = Calendar.current
    private var offset: TimeInterval = 0
    private var source: CalendarGridEvent?
    private var edge = CalendarEditGeometry.Edge.move
    func begin(_ event: CalendarGridEvent, edge: CalendarEditGeometry.Edge, at point: CGPoint) {
        source = event; self.edge = edge
        offset = date(at: point)?.timeIntervalSince(event.start) ?? 0
    }
    private func date(at point: CGPoint) -> Date? {
        guard let (day, frame) = frames.first(where: { point.x >= $0.value.minX && point.x < $0.value.maxX }), scale > 0 else { return nil }
        let minute = max(0, min(1439, Double(startHour * 60) + Double((point.y - frame.minY - 8) / scale)))
        let whole = Int(minute)
        return calendar.date(bySettingHour: whole / 60, minute: whole % 60, second: Int((minute - Double(whole)) * 60), of: day)
    }
    func move(to point: CGPoint) {
        guard let event = source, viewport.contains(point), var target = date(at: point) else { preview = nil; return }
        if edge == .move { target = target.addingTimeInterval(-offset) }
        preview = Preview(event: event, interval: CalendarEditGeometry.proposal(start: event.start, end: event.end, target: target, edge: edge))
    }
    func finish(at point: CGPoint) -> Preview? { move(to: point); let result = preview; cancel(); return result }
    func cancel() { source = nil; preview = nil }

}

/// NSView pointer tracking survives SwiftUI ScrollView's gesture arbitration.
struct CalendarDragSurface: NSViewRepresentable {
    let title: String
    let open: () -> Void
    let begin: (CalendarEditGeometry.Edge, CGPoint) -> Void
    let move: (CGPoint) -> Void
    let finish: (CGPoint) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.open = open; view.begin = begin; view.move = move; view.finish = finish; view.cancel = cancel
        view.setAccessibilityLabel(title + ", movable calendar event")
        view.setAccessibilityHelp("Drag to another time or day. Drag the top or bottom edge to resize. Activate for details and keyboard time editing. Escape cancels.")
    }
    final class DragView: NSView {
        var open: () -> Void = {}
        var begin: (CalendarEditGeometry.Edge, CGPoint) -> Void = { _, _ in }
        var move: (CGPoint) -> Void = { _ in }
        var finish: (CGPoint) -> Void = { _ in }
        var cancel: () -> Void = {}
        private var origin: CGPoint?
        private var dragged = false
        private var cancelled = false
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.button) }
        required init?(coder: NSCoder) { fatalError("Not used") }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
            let size = min(5, bounds.height / 4)
            addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: size), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: 0, y: bounds.height - size, width: bounds.width, height: size), cursor: .resizeUpDown)
        }
        private func point(_ event: NSEvent) -> CGPoint? {
            guard let root = window?.contentView else { return nil }
            let p = root.convert(event.locationInWindow, from: nil)
            return CGPoint(x: p.x, y: root.isFlipped ? p.y : root.bounds.height - p.y)
        }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self); origin = event.locationInWindow; dragged = false; cancelled = false
            let y = convert(event.locationInWindow, from: nil).y, size = min(5, bounds.height / 4)
            let edge: CalendarEditGeometry.Edge = y <= size ? .start : y >= bounds.height - size ? .end : .move
            if let p = point(event) { begin(edge, p) }
        }
        override func mouseDragged(with event: NSEvent) {
            guard !cancelled, let origin, hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4, let p = point(event) else { return }
            dragged = true; _ = autoscroll(with: event); move(p)
        }
        override func mouseUp(with event: NSEvent) {
            defer { origin = nil; dragged = false }
            guard !cancelled else { return }
            if dragged, let p = point(event) { finish(p) }
            else { cancel(); if bounds.contains(convert(event.locationInWindow, from: nil)) { open() } }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancelled = true; cancel() }
            else if event.keyCode == 36 || event.keyCode == 49 { open() }
            else { super.keyDown(with: event) }
        }
        override func accessibilityPerformPress() -> Bool { open(); return true }
        override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { cancel() }; super.viewWillMove(toWindow: newWindow) }
    }
}
