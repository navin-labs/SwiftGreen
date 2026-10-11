import AppKit
import CoreGraphics

// Renders the SwiftGreen app icon at 1024 px. Usage: swift render.swift - <out.png> [full|mac|bg|fg|mono|stat]
// The bird is design/icon/swiftgreen-mark.svg; regenerate every packaged icon with design/icon/build.sh.
// full: the squircle master (website, docs). mac: the macOS app icon, full bleed, since macOS 26 draws
// its own shape and would otherwise shrink a pre-shaped icon onto a plate. bg / fg / mono: Android layers.

let args = CommandLine.arguments
let out = args.count > 2 ? args[2] : "icon.png"
let mode = args.count > 3 ? args[3] : "full"   // full (squircle master) | mac (full bleed: macOS 26 applies its own shape) | bg | fg | mono (Android adaptive layers) | stat (Android status bar)
let bleed = mode != "full"
let S: CGFloat = 1024

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)   // y down
func save() {
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}

func c(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [w, w, w, a])! }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// Apple macOS grid: 824 px body centred in 1024, superellipse corners.
func squircle(_ rect: CGRect) -> CGPath {
    let p = CGMutablePath(); let n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st >= 0 ? 1 : -1) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath(); return p
}

let body = bleed ? CGRect(x: 0, y: 0, width: S, height: S) : CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = bleed ? CGPath(rect: body, transform: nil) : squircle(body)

// Tile: the website's night colour (#05070d), flat, exactly as the site's favicon and header mark (D154).
func srgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
if mode == "full" || mode == "bg" || mode == "mac" {
    ctx.addPath(shape); ctx.setFillColor(srgb(0x05070d)); ctx.fillPath()
}

// The bird: the SwiftGreen mark (swiftgreen-mark.svg, the website's "bank" swift, D154), one path of absolute
// M/C/Z commands in a 100 box. It is fitted by its own bounds into a square of side `fit`, centred.
if mode == "bg" { save(); exit(0) }
let svgURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("swiftgreen-mark.svg")
let svg = try! String(contentsOf: svgURL, encoding: .utf8)
let d = svg.range(of: #"d="([^"]+)""#, options: .regularExpression).map { String(svg[$0].dropFirst(3).dropLast()) }!
let mark = CGMutablePath()
var tokens = d.split(whereSeparator: { $0 == " " || $0 == "," }).flatMap { tok -> [Substring] in
    // "M38.88" / "C37.49" / "8.00C37.49" carry a command letter inside the token; split it off.
    var out: [Substring] = []; var cur = tok.startIndex
    for i in tok.indices where "MCZ".contains(tok[i]) {
        if cur < i { out.append(tok[cur..<i]) }
        out.append(tok[i...i]); cur = tok.index(after: i)
    }
    if cur < tok.endIndex { out.append(tok[cur...]) }
    return out
}[...]
func num() -> CGFloat { CGFloat(Double(tokens.removeFirst())!) }
while let cmd = tokens.first {
    tokens.removeFirst()
    switch cmd {
    case "M": mark.move(to: CGPoint(x: num(), y: num()))
    case "C": while let t = tokens.first, !"MCZ".contains(t) {
        let c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num()), e = CGPoint(x: num(), y: num())
        mark.addCurve(to: e, control1: c1, control2: c2) }
    case "Z": mark.closeSubpath()
    default: fatalError("swiftgreen-mark.svg: only absolute M, C and Z are supported, found \(cmd)")
    }
}

// Mark size: macOS keeps the bird inside its 824 body; Android inside the 66 dp safe zone of 108 dp (61%,
// less a margin so the tips never touch the mask); the status-bar icon fills its box.
// The website's favicon puts the bird in 24 of 32 px (75%); the same ratio here. Android stays inside the 66 dp safe zone.
let fit: CGFloat = mode == "stat" ? S * 0.94 : mode == "full" ? 824 * 0.75 : mode == "mac" ? S * 0.75 : S * 0.58
let bb = mark.boundingBoxOfPath
let k = fit / max(bb.width, bb.height)
var place = CGAffineTransform(translationX: S / 2, y: S / 2).scaledBy(x: k, y: k).translatedBy(x: -bb.midX, y: -bb.midY)
let bird = mark.copy(using: &place)!

if mode == "mono" || mode == "stat" {
    ctx.addPath(bird); ctx.setFillColor(c(1)); ctx.fillPath()
} else {   // the website's bird colour (#dfe6f5), flat
    ctx.addPath(bird); ctx.setFillColor(srgb(0xdfe6f5)); ctx.fillPath()
}

save()
