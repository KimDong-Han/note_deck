import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageTools {
    public static let iconSize: CGFloat = 128
    public static let maxGifFrames = 48
    public static let maxGifBytes = 600_000

    /// Encode a file as a deck icon: animated GIF -> resized GIF (keeps animation), anything else -> 128px PNG. Base64.
    public static func encodeIcon(from url: URL) -> String? {
        if let gif = animatedGIF(from: url) { return gif.base64EncodedString() }
        return pngData(from: url)?.base64EncodedString()
    }

    public static func image(base64: String) -> NSImage? {
        guard let d = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: d)
    }

    /// Rough USB-MIDI transfer time (measured ≈ 23 KB/s of base64).
    public static func transferSeconds(base64: String) -> Int { max(1, base64.count / 23_000) }

    public static func isGIF(base64: String) -> Bool { base64.hasPrefix("R0lGOD") }   // "GIF8" in base64

    // MARK: PNG
    private static func pngData(from url: URL) -> Data? {
        guard let src = NSImage(contentsOf: url) else { return nil }
        let size = Int(iconSize)
        // draw into an explicit 1x bitmap (lockFocus would use the Retina scale and double the payload)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let s = src.size
        let scale = min(CGFloat(size) / max(s.width, 1), CGFloat(size) / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        src.draw(in: NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: animated GIF (ImageIO): resize every frame, keep delays, loop forever
    private static func animatedGIF(from url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?, type == UTType.gif.identifier else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let step = max(1, Int((Double(count) / Double(maxGifFrames)).rounded(.up)))   // drop frames if too many
        let size = Int(iconSize)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, (count + step - 1) / step, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var i = 0
        while i < count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil) else { i += step; continue }
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            delay = max(0.02, delay * Double(step))
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let fw = CGFloat(frame.width), fh = CGFloat(frame.height)
            let scale = min(CGFloat(size) / max(fw, 1), CGFloat(size) / max(fh, 1))
            let w = fw * scale, h = fh * scale
            ctx.interpolationQuality = .high
            ctx.draw(frame, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
            if let scaled = ctx.makeImage() {
                CGImageDestinationAddImage(dest, scaled, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            i += step
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        if out.length > maxGifBytes { Log.warn("gif too large after resize (\(out.length) bytes), using first frame"); return nil }
        return out as Data
    }
}
