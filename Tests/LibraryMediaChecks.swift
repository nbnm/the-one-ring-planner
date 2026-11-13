import Foundation
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import RingCore

@main enum LibraryMediaChecks {
    static func main() throws {
        var failures = 0, count = 0
        func check(_ value: Bool, _ message: String) { count += 1; if !value { failures += 1 }; print("\(value ? "PASS" : "FAIL") \(message)") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ring-library-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try DataRepository(root: base.appendingPathComponent("Data"), localState: base.appendingPathComponent("Local"))
        let png = try LibraryMedia.png(width: 128, height: 96) { _,_ in (180,40,20) }
        let pngURL = base.appendingPathComponent("original.png"); try png.write(to: pngURL)
        let bitmap = NSBitmapImageRep(data: png)!, color = bitmap.colorAt(x: 12,y: 12)!.usingColorSpace(.sRGB)!
        check(color.alphaComponent > 0.99 && color.redComponent > 0.6 && color.greenComponent < 0.3, "Generated vision/demo images contain opaque colored pixels")
        let clipboard = try LibraryMedia.clipboardImage(png, localState: repo.localState)
        check(try Data(contentsOf: clipboard) == png, "Pasted PNG keeps the original bytes")
        let source = CGImageSourceCreateWithData(png as CFData, nil)!, image = CGImageSourceCreateImageAtIndex(source,0,nil)!
        func encoded(_ type: UTType) throws -> Data {
            let data = NSMutableData(); guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString,1,nil) else { throw LibraryError.invalid("Missing image codec") }
            CGImageDestinationAddImage(destination,image,nil); guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalid("Image encoding failed") }; return data as Data
        }
        let jpeg = try encoded(.jpeg), jpegURL = try LibraryMedia.clipboardImage(jpeg, localState: repo.localState)
        let board = NSPasteboard(name: .init("one-ring-clipboard-check-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setData(png, forType: .png); first.setString("Exact text\n\tТочный текст.", forType: .string)
        second.setData(jpeg, forType: .init(UTType.jpeg.identifier))
        board.writeObjects([first, second])
        let pasted = CaptureClipboard.read(board)
        check(pasted.images == [png, jpeg] && pasted.text == "Exact text\n\tТочный текст.", "Mixed clipboard capture preserves every image and accompanying literal text")
        let editor = LibraryTextEditor.PasteView(frame: .zero)
        editor.isRichText = false; editor.importsGraphics = false
        var delivered: [Data] = []; editor.onImage = { delivered.append($0) }
        check(editor.readablePasteboardTypes.contains(.png) && editor.readablePasteboardTypes.contains(.tiff), "Plain capture editor advertises image types so macOS enables Paste for image-only clipboards")
        check(editor.capture(board) && delivered == [png,jpeg] && editor.string == "Exact text\n\tТочный текст.", "Task and Note editor paste inserts text and routes multiple images together")
        board.clearContents(); board.setData(png, forType: .png)
        delivered = []; editor.string = ""
        check(editor.readSelection(from: board, type: .png) && delivered == [png] && editor.string.isEmpty, "AppKit image-only paste dispatch attaches the original without inserting text")
        board.clearContents(); let gif = try encoded(.gif); board.setData(gif, forType: .init(UTType.gif.identifier))
        let genericImage = CaptureClipboard.read(board)
        check(genericImage.images == [gif] && (try? LibraryMedia.clipboardImage(gif, localState: repo.localState).pathExtension) == "png", "Other advertised image clipboard formats convert to a usable PNG attachment")
        let rich = NSMutableAttributedString(string: "Two references\n")
        for (name, bytes) in [("one.png",png),("two.jpg",jpeg)] {
            let wrapper = FileWrapper(regularFileWithContents: bytes); wrapper.preferredFilename = name
            rich.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        }
        board.clearContents()
        board.setData(rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!, forType: .rtfd)
        board.setData(png, forType: .png)
        let embedded = CaptureClipboard.read(board)
        check(embedded.images.count == 2 && embedded.text == "Two references\n", "Rich-text clipboard keeps individual images instead of a flattened preview")
        board.clearContents(); board.setString("https://example.com/fellowship?map=1", forType: .init(UTType.url.identifier))
        let linkEditor = LibraryTextEditor.PasteView(frame: .zero)
        check(linkEditor.capture(board) && linkEditor.string == "https://example.com/fellowship?map=1", "URL-only clipboard content pastes as a reusable link")
        let pastedJPEG = try Data(contentsOf: jpegURL)
        check(jpegURL.pathExtension == "jpg" && pastedJPEG == jpeg, "Pasted JPEG keeps its actual format and original bytes")
        let converted = try LibraryMedia.clipboardImage(encoded(.tiff), localState: repo.localState)
        check(converted.pathExtension == "png" && CGImageSourceCreateWithURL(converted as CFURL,nil) != nil, "Clipboard TIFF is converted to a valid lossless PNG")
        let markdown = "# Exact\r\n\t```swift\nlet value = `literal`\n```\nТочный текст."
        let mdURL = base.appendingPathComponent("SKILL.md"); try Data(markdown.utf8).write(to: mdURL)
        let files = try LibraryMedia.prepare([pngURL,mdURL], repository: repo)
        let note = LibraryNote(body: markdown, attachments: files.map(\.attachment)); try repo.saveLibrary(note, expectedRevision: nil, attachments: files.map(\.write))
        check(try Data(contentsOf: repo.validatedURL(files[1].attachment.path)) == Data(markdown.utf8), "Markdown imports preserve CRLF, tabs, code and Cyrillic text")
        check(try LibraryMedia.recognize(files[1].attachment, repository: repo) == markdown, "Attached skills are indexed even when the note has its own body")
        let thumbnail = try LibraryMedia.thumbnail(files[0].attachment, repository: repo)
        check(thumbnail?.path.hasPrefix(repo.localState.path) == true && thumbnail.flatMap(NSImage.init(contentsOf:)) != nil, "Thumbnails are usable derived files outside Git")
        let large = base.appendingPathComponent("oversized.png"); FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: UInt64(LibraryPolicy.maximumAttachmentBytes + 1)); try handle.close()
        do { _ = try LibraryMedia.prepare([large], repository: repo); check(false,"Oversized input is rejected before loading") } catch { check(true,"Oversized input is rejected before loading") }
        let context = CGContext(data:nil,width:1000,height:240,bitsPerComponent:8,bytesPerRow:4000,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:1000,height:240)); context.setFillColor(CGColor(gray:0,alpha:1))
        let font = CTFontCreateWithName("Helvetica" as CFString,40,nil)
        for (line,y) in [("FELLOWSHIP REFERENCE",150.0),("ТИХАЯ БИБЛИОТЕКА",70.0)] {
            let string = NSAttributedString(string:line,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font, NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
            context.textPosition = CGPoint(x:30,y:y); CTLineDraw(CTLineCreateWithAttributedString(string),context)
        }
        let textURL = base.appendingPathComponent("ocr.png"), destination = CGImageDestinationCreateWithURL(textURL as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil); guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalid("OCR fixture failed") }
        let textAsset = try LibraryMedia.prepare([textURL], repository:repo)[0]
        try repo.saveLibrary(LibraryNote(attachments:[textAsset.attachment]), expectedRevision:nil, attachments:[textAsset.write])
        let ocr = try LibraryMedia.recognize(textAsset.attachment, repository:repo).uppercased()
        check(ocr.contains("FELLOWSHIP") && ocr.contains("БИБЛИОТЕКА"), "Apple Vision OCR recognizes generated English and Russian reference text locally")
        print("Library native media: \(count) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
