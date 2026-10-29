import AppKit

let output = CommandLine.arguments[1]
let source = CommandLine.arguments[2]
guard let ring = NSImage(contentsOfFile: source) else { fatalError("Ring artwork is missing: \(source)") }
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 10, y: 10, width: 1004, height: 1004), xRadius: 220, yRadius: 220)
NSColor(srgbRed: 0.11, green: 0.13, blue: 0.10, alpha: 1).setFill()
background.fill()
NSGraphicsContext.current?.imageInterpolation = .high
ring.draw(in: NSRect(x: 110, y: 110, width: 804, height: 804), from: .zero, operation: .sourceOver, fraction: 1)
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode the app icon") }
try png.write(to: URL(fileURLWithPath: output))
