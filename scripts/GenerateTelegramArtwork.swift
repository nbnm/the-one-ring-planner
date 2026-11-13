import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard let sourceRing = NSImage(contentsOf: root.appendingPathComponent("Sources/RingPlanner/Assets/OneRing.png")), let sourceCG = sourceRing.cgImage(forProposedRect:nil,context:nil,hints:nil) else { fatalError("Missing app ring artwork") }
// Keep the established ring silhouette while dropping isolated matte debris in its transparent centre.
let width=sourceCG.width, height=sourceCG.height
var pixels=[UInt8](repeating:0,count:width*height*4)
let rgba=CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
rgba.draw(sourceCG,in:CGRect(x:0,y:0,width:width,height:height))
var seen=[Bool](repeating:false,count:width*height), largest:[Int]=[]
for start in 0..<(width*height) where !seen[start] && pixels[start*4+3]>8 {
    var component=[start], cursor=0;seen[start]=true
    while cursor<component.count {
        let index=component[cursor],x=index%width,y=index/width;cursor+=1
        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
            let nx=x+dx,ny=y+dy
            if nx>=0 && nx<width && ny>=0 && ny<height { let n=ny*width+nx; if !seen[n] && pixels[n*4+3]>8 { seen[n]=true;component.append(n) } }
        } }
    }
    if component.count>largest.count { largest=component }
}
let keep=Set(largest)
for index in 0..<(width*height) where !keep.contains(index) { pixels[index*4]=0;pixels[index*4+1]=0;pixels[index*4+2]=0;pixels[index*4+3]=0 }
let provider=CGDataProvider(data:Data(pixels) as CFData)!
let clean=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
let ring=NSImage(cgImage:clean,size:NSSize(width:width,height:height))
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: alpha) }
func render(width: Int, height: Int, to path: String, draw: (CGContext) -> Void) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:width, pixelsHigh:height, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0), let context = NSGraphicsContext(bitmapImageRep:rep) else { fatalError("Artwork context unavailable") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context; draw(context.cgContext); NSGraphicsContext.restoreGraphicsState()
    let file = root.appendingPathComponent(path); try FileManager.default.createDirectory(at:file.deletingLastPathComponent(), withIntermediateDirectories:true)
    try rep.representation(using:.jpeg, properties:[.compressionFactor:0.94])!.write(to:file, options:.atomic)
}
try render(width:1024,height:1024,to:"Sources/RingPlanner/Assets/TelegramAvatar.jpg") { context in
    NSGradient(colors:[color(0x365742),color(0x152A20)])!.draw(in:NSBezierPath(rect:NSRect(x:0,y:0,width:1024,height:1024)),angle:270)
    NSGradient(colors:[color(0xC5A75B,alpha:0.27),color(0xD6B56B,alpha:0)])!.draw(fromCenter:NSPoint(x:490,y:530),radius:30,toCenter:NSPoint(x:490,y:530),radius:530,options:[.drawsBeforeStartingLocation,.drawsAfterEndingLocation])
    color(0xD6B56B,alpha:0.42).setStroke(); let circle=NSBezierPath(ovalIn:NSRect(x:100,y:100,width:824,height:824)); circle.lineWidth=2;circle.stroke()
    color(0xD6B56B,alpha:0.15).setStroke(); let outer=NSBezierPath(ovalIn:NSRect(x:82,y:82,width:860,height:860));outer.lineWidth=1;outer.stroke()
    // Large central mark stays inside Telegram's circular crop at every avatar size.
    context.saveGState(); context.setShadow(offset:CGSize(width:0,height:-18),blur:35,color:NSColor.black.withAlphaComponent(0.45).cgColor)
    ring.draw(in:NSRect(x:135,y:135,width:754,height:754),from:.zero,operation:.sourceOver,fraction:1)
    context.restoreGState()
}
try render(width:1440,height:2560,to:"docs/telegram/shire-chat-wallpaper.jpg") { context in
    NSGradient(colors:[color(0x354A39),color(0x1B2E23)])!.draw(in:NSBezierPath(rect:NSRect(x:0,y:0,width:1440,height:2560)),angle:270)
    NSGradient(colors:[color(0xC5B880,alpha:0.16),color(0xC5B880,alpha:0)])!.draw(fromCenter:NSPoint(x:1120,y:2270),radius:10,toCenter:NSPoint(x:1120,y:2270),radius:800,options:[.drawsBeforeStartingLocation,.drawsAfterEndingLocation])
    color(0xC8C28A,alpha:0.35).setFill();NSBezierPath(ovalIn:NSRect(x:1060,y:2180,width:140,height:140)).fill()
    let tones:[UInt32]=[0x455B3D,0x344F35,0x294631,0x203B2B]
    for layer in 0..<4 {
        let y=CGFloat(700-layer*140), path=NSBezierPath();path.move(to:NSPoint(x:0,y:y))
        path.curve(to:NSPoint(x:1440,y:y-80),controlPoint1:NSPoint(x:480,y:y+240),controlPoint2:NSPoint(x:850,y:y-180))
        path.line(to:NSPoint(x:1440,y:0));path.line(to:.zero);path.close();color(tones[layer]).setFill();path.fill()
    }
    let path=NSBezierPath();path.move(to:NSPoint(x:700,y:0));path.curve(to:NSPoint(x:1160,y:540),controlPoint1:NSPoint(x:960,y:140),controlPoint2:NSPoint(x:850,y:370));path.curve(to:NSPoint(x:800,y:0),controlPoint1:NSPoint(x:910,y:280),controlPoint2:NSPoint(x:1140,y:140));path.close();color(0x9E925C,alpha:0.27).setFill();path.fill()
    let hill=NSBezierPath();hill.move(to:NSPoint(x:80,y:160));hill.curve(to:NSPoint(x:720,y:160),controlPoint1:NSPoint(x:140,y:650),controlPoint2:NSPoint(x:610,y:650));hill.close();color(0x3D5535).setFill();hill.fill()
    color(0xA88B4C,alpha:0.7).setFill();NSBezierPath(ovalIn:NSRect(x:296,y:160,width:182,height:205)).fill()
    color(0x73532F).setFill();NSBezierPath(ovalIn:NSRect(x:307,y:169,width:160,height:185)).fill()
    color(0xD6B56B).setFill();NSBezierPath(ovalIn:NSRect(x:392,y:250,width:10,height:10)).fill()
    // Quiet texture; the centre remains clear so real Telegram messages stay readable.
    for i in 0..<130 {
        let x=CGFloat((i*109+19)%1440),y=CGFloat((i*73+11)%430)
        color(i%3==0 ? 0xC7AE6D : 0x95A06A,alpha:0.20).setFill();NSBezierPath(ovalIn:NSRect(x:x,y:y,width:3,height:3)).fill()
    }
}
print("Generated Telegram avatar and Shire chat wallpaper")
