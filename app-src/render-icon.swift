// render-icon.swift — アプリアイコン（NFC 非接触マーク）を各サイズの PNG として出力する。
// CoreGraphics + ImageIO のみ（ウインドウ不要・ヘッドレスで動く）。
// 使い方: render-icon <出力iconsetディレクトリ>
import CoreGraphics
import ImageIO
import Foundation

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func drawIcon(size: Int, to path: String) {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS アイコングリッド: 1024 中 824 の角丸タイル（周囲 100px 余白）
    let margin = s * (100.0 / 1024.0)
    let tile = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 影付きでベースを塗る
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: color(0, 0, 0, 0.32))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.31, 0.27, 0.90))
    ctx.fillPath()
    ctx.restoreGState()

    // 角丸内にクリップして対角グラデーション（インディゴ→ティール）
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [color(0.33, 0.28, 0.93), color(0.02, 0.72, 0.85)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // 上部に淡い光沢
    let gloss = CGGradient(colorsSpace: cs,
                           colors: [color(1, 1, 1, 0.18), color(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.midY), options: [])
    ctx.restoreGState()

    // 非接触マーク（右に開く 3 本の弧 + 発信点ドット）
    let cx = tile.minX + tile.width * 0.36
    let cy = tile.midY
    ctx.setStrokeColor(color(1, 1, 1, 1))
    ctx.setLineCap(.round)
    let lw = tile.width * 0.055
    ctx.setLineWidth(lw)
    let baseR = tile.width * 0.135
    let step = tile.width * 0.125
    let a = CGFloat(50) * .pi / 180
    for i in 0..<3 {
        let r = baseR + CGFloat(i) * step
        let p = CGMutablePath()
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                 startAngle: -a, endAngle: a, clockwise: false)
        ctx.addPath(p)
        ctx.strokePath()
    }
    let dotR = tile.width * 0.04
    ctx.setFillColor(color(1, 1, 1, 1))
    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: 2 * dotR, height: 2 * dotR))

    guard let img = ctx.makeImage() else { return }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dst = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

let jobs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, sz) in jobs { drawIcon(size: sz, to: outDir + "/" + name) }
print("wrote iconset -> \(outDir)")
