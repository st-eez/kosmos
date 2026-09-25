// Draws the app icon: the cosmos as one matte sphere, split once, with the cut the only light.
// Renders the macOS iconset from vectors at every size, so nothing is downsampled. The result
// is checked in as Resources/Kosmos.icns; after a change here, regenerate it with
//
//   swift script/icon.swift /tmp/Kosmos.iconset && iconutil -c icns /tmp/Kosmos.iconset -o Resources/Kosmos.icns
//
// The body fills macOS 27's icon mask (see `draw`), so macOS shows the .icns at full size
// instead of shrinking it onto a grey rounded square.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let everywhere = CGRect(x: -4000, y: -4000, width: 9000, height: 9000)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// A rounded rectangle whose corners are superellipse quarters, `s` across, with the exponent
/// of the macOS 27 icon mask.
func superellipse(_ rect: CGRect, corner s: CGFloat) -> CGPath {
    let m: CGFloat = 2.78
    let centers = [(CGPoint(x: rect.maxX - s, y: rect.minY + s), 1.5 * CGFloat.pi),
                   (CGPoint(x: rect.maxX - s, y: rect.maxY - s), 0),
                   (CGPoint(x: rect.minX + s, y: rect.maxY - s), 0.5 * .pi),
                   (CGPoint(x: rect.minX + s, y: rect.minY + s), .pi)]
    let path = CGMutablePath()
    for (center, start) in centers {
        for step in 0...96 {
            let t = start + CGFloat(step) / 96 * .pi / 2
            let point = CGPoint(x: center.x + s * copysign(pow(abs(cos(t)), 2 / m), cos(t)),
                                y: center.y + s * copysign(pow(abs(sin(t)), 2 / m), sin(t)))
            path.isEmpty ? path.move(to: point) : path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

/// A bitmap in 1024 point coordinates, whatever its pixel size. Shadow offsets and blurs are
/// in device space, so the helpers scale them.
final class Canvas {
    let ctx: CGContext
    let scale: CGFloat
    /// At 64 px and below the artwork simplifies a little, as Apple's own icons do: a wider
    /// cut and no fine dark margin beside it. At 16 px the cut widens again to stay a line.
    var small: Bool { scale <= 64.0 / 1024 }
    var tiny: Bool { scale <= 16.0 / 1024 }

    init(px: Int) {
        ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        scale = CGFloat(px) / 1024
        ctx.scaleBy(x: scale, y: scale)
    }
    var image: CGImage { ctx.makeImage()! }

    func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
    }
    func clipped(_ path: CGPath, _ draw: () -> Void) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip(); draw(); ctx.restoreGState()
    }
    func fill(_ path: CGPath, _ color: CGColor) {
        ctx.saveGState(); ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath(); ctx.restoreGState()
    }
    /// Fills `path` with a top to bottom gradient.
    func fill(_ path: CGPath, top: CGColor, bottom: CGColor) {
        let box = path.boundingBox
        clipped(path) {
            ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }
    /// A linear gradient across the current clip.
    func wash(_ colors: [CGColor], from: CGPoint, to: CGPoint, _ locations: [CGFloat]? = nil) {
        ctx.drawLinearGradient(gradient(colors, locations), start: from, end: to, options: [])
    }
    func radial(_ center: CGPoint, _ radius: CGFloat, _ colors: [CGColor], _ locations: [CGFloat]? = nil) {
        ctx.drawRadialGradient(gradient(colors, locations), startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: radius, options: [])
    }
    /// Shadow (or glow, with no offset) cast by `path` onto everything outside it.
    func shadow(_ path: CGPath, _ color: CGColor, blur: CGFloat, dy: CGFloat = 0) {
        ctx.saveGState()
        ctx.addRect(everywhere); ctx.addPath(path); ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: dy * scale), blur: blur * scale, color: color)
        ctx.addPath(path); ctx.setFillColor(rgb(0)); ctx.fillPath()
        ctx.restoreGState()
    }
    /// A rim of light just inside the edge of `path`, bright at the top and faint at the bottom.
    func rim(_ path: CGPath, width: CGFloat, top: CGFloat, bottom: CGFloat) {
        let box = path.boundingBox
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.addPath(path); ctx.setLineWidth(width * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0xffffff, top), rgb(0xffffff, top * 0.15), rgb(0xffffff, bottom)], [0, 0.55, 1]),
                               start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

/// The icon body, then the sphere and its cut.
func draw(_ c: Canvas) {
    // macOS 27's icon mask, measured from Terminal's icon at 1024 px: an 824 px body inside a
    // 100 px margin, corners a superellipse quarter 34% of the side across, exponent 2.78
    // (in `superellipse`).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = superellipse(body, corner: body.width * 0.34)
    c.shadow(bodyPath, rgb(0, 0.5), blur: 24, dy: -10)
    c.clipped(bodyPath) {
        c.fill(bodyPath, top: rgb(0x15171d), bottom: rgb(0x0a0b0e))
        let center = CGPoint(x: 512, y: 512)
        let r: CGFloat = 300
        let sphere = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
        let vx: CGFloat = 512 + 28
        let gap: CGFloat = c.tiny ? 96 : c.small ? 64 : 46
        let leftHalf = CGPath(rect: CGRect(x: -100, y: -100, width: vx - gap / 2 + 100, height: 1300), transform: nil)
        let rightHalf = CGPath(rect: CGRect(x: vx + gap / 2, y: -100, width: 1300, height: 1300), transform: nil)
        let slot = CGPath(rect: CGRect(x: vx - gap / 2, y: center.y - r + 6, width: gap, height: r * 2 - 12), transform: nil)

        // Light escaping where the halves part, above and below the sphere.
        for y in [center.y + r, center.y - r] {
            c.radial(CGPoint(x: vx, y: y), 230, [rgb(0xffc36a, 0.7), rgb(0xff9a4a, 0.22), rgb(0xff9a4a, 0)], [0, 0.35, 1])
        }
        // The cut: a white core cooling toward the faces, with a dark margin at full size.
        let hot = c.small ? [rgb(0xfffaf0), rgb(0xffeac2), rgb(0xffb26a), rgb(0xd9702f)]
                          : [rgb(0xfff9ee), rgb(0xffe2a6), rgb(0xffa657), rgb(0xb8552a), rgb(0x2a140c)]
        let stops: [CGFloat] = c.small ? [0, 0.5, 0.85, 1] : [0, 0.35, 0.7, 0.9, 1]
        c.clipped(slot) {
            c.wash(hot, from: CGPoint(x: vx, y: 0), to: CGPoint(x: vx + gap / 2, y: 0), stops)
            c.wash(hot, from: CGPoint(x: vx, y: 0), to: CGPoint(x: vx - gap / 2, y: 0), stops)
        }

        c.shadow(sphere, rgb(0, 0.6), blur: 34, dy: -16)
        for half in [leftHalf, rightHalf] {
            c.clipped(half) {
                c.fill(sphere, top: rgb(0x2e323b), bottom: rgb(0x101216))
                c.clipped(sphere) {
                    c.radial(CGPoint(x: 400, y: 640), 420, [rgb(0xffffff, 0.22), rgb(0xffffff, 0.05), rgb(0xffffff, 0)], [0, 0.5, 1])
                }
                c.rim(sphere, width: 5, top: 0.5, bottom: 0.12)
            }
        }
        // Bloom over the sphere's skin beside the cut, and the lit cut faces.
        c.clipped(sphere) {
            c.shadow(slot, rgb(0xff9a4a, 0.5), blur: 60)
            c.shadow(slot, rgb(0xffc98a, 0.7), blur: 18)
            c.fill(CGPath(rect: CGRect(x: vx - gap / 2 - 4, y: center.y - r, width: 4, height: r * 2), transform: nil), rgb(0xfff1d6, 0.85))
            c.fill(CGPath(rect: CGRect(x: vx + gap / 2, y: center.y - r, width: 4, height: r * 2), transform: nil), rgb(0xfff1d6, 0.85))
        }
    }
    c.rim(bodyPath, width: 6, top: 0.22, bottom: 0.06)
}

func write(px: Int, to url: URL) throws {
    let canvas = Canvas(px: px)
    draw(canvas)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, canvas.image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasSuffix(".iconset") else {
    FileHandle.standardError.write(Data("usage: swift script/icon.swift OUT.iconset\n".utf8))
    exit(2)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try write(px: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try write(px: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
