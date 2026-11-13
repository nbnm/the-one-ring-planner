import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Plain text editing deliberately disables smart quotes, substitutions and rich text.
struct LibraryTextEditor: NSViewRepresentable {
    @Binding var text: String
    var label = "Note text"
    var initialFocus = false
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = PasteView(frame: NSRect(x: 0, y: 0, width: 560, height: 170)); editor.isRichText = false; editor.importsGraphics = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular); editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.string = text; editor.delegate = context.coordinator; editor.setAccessibilityLabel(label)
        editor.onFiles = onFiles; editor.onImage = onImage
        editor.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier), .string])
        scroll.documentView = editor
        if initialFocus { DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) } }; return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = view.documentView as? PasteView {
            if editor.string != text { let range = editor.selectedRange(); editor.string = text; editor.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0)) }
            editor.textColor = .labelColor; editor.onFiles = onFiles; editor.onImage = onImage
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LibraryTextEditor
        init(_ parent: LibraryTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
    final class PasteView: NSTextView {
        var onFiles: (([URL]) -> Void)?
        var onImage: ((Data) -> Void)?
        // AppKit validates Edit → Paste before dispatching Command-V. A plain NSTextView
        // omits image types even when paste(_:) is overridden to handle them.
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            var types = super.readablePasteboardTypes
            if onFiles != nil { types.append(.fileURL) }
            if onImage != nil { types += CaptureClipboard.imageTypes }
            return types
        }
        override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            if capture(pasteboard) { return true }
            return super.readSelection(from: pasteboard, type: type)
        }
        func capture(_ pasteboard: NSPasteboard) -> Bool {
            let content = CaptureClipboard.read(pasteboard)
            guard (!content.files.isEmpty && onFiles != nil) || (!content.images.isEmpty && onImage != nil) || content.text != nil else { return false }
            if !content.files.isEmpty { onFiles?(content.files) }
            for image in content.images { onImage?(image) }
            if let text = content.text, !text.isEmpty { insertText(text, replacementRange: selectedRange()) }
            return true
        }
        override func paste(_ sender: Any?) { if !capture(.general) { pasteAsPlainText(sender) } }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { capture(sender.draggingPasteboard) || super.performDragOperation(sender) }
    }
}

/// Read every pasteboard item; never fetch remote images from HTML.
enum CaptureClipboard {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier), .init(UTType.image.identifier)]
    struct Content { var text: String?; var files: [URL] = []; var images: [Data] = [] }
    static func read(_ board: NSPasteboard) -> Content {
        var result = Content()
        result.files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !result.files.isEmpty { return result }
        let types: [NSPasteboard.PasteboardType] = [.png, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier), .tiff]
        for item in board.pasteboardItems ?? [] {
            if let data = types.lazy.compactMap({ item.data(forType: $0) }).first { result.images.append(data) }
            else if let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }), let data = item.data(forType: type) { result.images.append(data) }
        }
        if let data = board.data(forType: .rtfd), let rich = NSAttributedString(rtfd: data, documentAttributes: nil) {
            var embedded: [Data] = []
            rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment, let bytes = attachment.fileWrapper?.regularFileContents ?? attachment.image?.tiffRepresentation, NSImage(data: bytes) != nil { embedded.append(bytes) }
            }
            if !embedded.isEmpty { result.images = embedded }
            result.text = board.string(forType: .string) ?? rich.string.replacingOccurrences(of: "\u{fffc}", with: "")
        } else { result.text = board.string(forType: .string) ?? board.string(forType: NSPasteboard.PasteboardType(UTType.url.identifier)) }
        return result
    }
}
