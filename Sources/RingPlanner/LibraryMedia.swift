import AppKit
import ImageIO
import Vision
import UniformTypeIdentifiers
import RingCore

struct LibraryMedia {
    static let supported: [UTType] = [.png, .jpeg, .heic, .plainText, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
    static func png(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> Data {
        guard width > 0, height > 0, width <= 8000, height <= 8000 else { throw LibraryError.invalid("Invalid generated image size.") }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let color = pixel(x,y), i = (y * width + x) * 4; bytes[i] = color.0; bytes[i+1] = color.1; bytes[i+2] = color.2 } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw LibraryError.invalid("Could not generate the image fixture.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw LibraryError.invalid("Could not encode the image fixture.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalid("Image encoding failed.") }; return output as Data
    }
    static func prepare(_ files: [URL], repository: DataRepository) throws -> [LibraryPreparedAttachment] {
        try files.map { url in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= LibraryPolicy.maximumAttachmentBytes else { throw LibraryError.invalid("Choose regular image or Markdown files up to 20 MB each.") }
            let bytes = try Data(contentsOf: url), ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "heic"].contains(ext) {
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw LibraryError.invalid("An image could not be decoded. Its source file is preserved.") }
            } else {
                guard ["md", "markdown", "txt"].contains(ext), String(data: bytes, encoding: .utf8) != nil else { throw LibraryError.invalid("Use UTF-8 Markdown/text or a PNG, JPEG or HEIC image.") }
            }
            return try LibraryAttachments.prepare(data: bytes, name: url.lastPathComponent, extension: ext, localState: repository.localState)
        }
    }
    static func thumbnail(_ attachment: LibraryAttachment, repository: DataRepository) throws -> URL? {
        guard attachment.isImage else { return nil }
        let file = repository.localState.appendingPathComponent("library-thumbnails/\(attachment.hash).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let url = try repository.validatedURL(attachment.path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }; return file
    }
    static func recognize(_ attachment: LibraryAttachment, repository: DataRepository) throws -> String {
        guard attachment.isImage else {
            let bytes = try Data(contentsOf: repository.validatedURL(attachment.path))
            guard bytes.count <= LibraryPolicy.maximumAttachmentBytes, let text = String(data: bytes, encoding: .utf8) else { throw LibraryError.invalid("The text attachment could not be indexed. Its original is preserved.") }
            return text
        }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US", "ru-RU"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: repository.validatedURL(attachment.path)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    static func aiImages(_ files: [URL]) throws -> [LibraryAIImage] {
        guard files.count <= 12 else { throw LibraryError.invalid("Use up to 12 images for AI task review, or save the larger set as a Library note.") }
        return try files.enumerated().map { index, file in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw LibraryError.invalid("An attached image could not be read. Your original is retained.") }
            let data = NSMutableData()
            guard let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw LibraryError.invalid("Could not prepare an image thumbnail.") }
            CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(target) else { throw LibraryError.invalid("Image preparation failed.") }
            return LibraryAIImage(id: "image-\(index)", bytes: data as Data)
        }
    }
    static func clipboardImage(_ data: Data, localState: URL) throws -> URL {
        guard data.count <= LibraryPolicy.maximumAttachmentBytes, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LibraryError.invalid("Could not read the pasted image.") }
        let originalType = CGImageSourceGetType(source).map { $0 as String }
        let ext = originalType == UTType.png.identifier ? "png" : originalType == UTType.jpeg.identifier ? "jpg" : originalType == UTType.heic.identifier ? "heic" : "png"
        let url = localState.appendingPathComponent("library-drafts/\(UUID().uuidString).\(ext)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier].contains(originalType ?? "") { try data.write(to: url, options: .atomic); return url }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw LibraryError.invalid("Could not prepare the pasted image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalid("Could not save the pasted image. Retry pasting it.") }; return url
    }
}
