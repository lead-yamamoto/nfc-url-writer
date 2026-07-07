// render-dmg-bg.swift — DMG ウインドウ用の背景 PNG を出力する。
// 中央に右向きの矢印、下部に「ドラッグして「アプリケーション」へ」の案内文。
// CoreGraphics + ImageIO + CoreText のみ（ウインドウ不要・ヘッドレスで動く）。
// 使い方: render-dmg-bg <出力PNGパス> [幅 高さ]
import CoreGraphics
import CoreText
import ImageIO
import Foundation

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "bg.png"
let W = args.count > 3 ? (Int(args[2]) ?? 600) : 600
let H = args.count > 3 ? (Int(args[3]) ?? 400) : 400

let w = CGFloat(W)
let h = CGFloat(H)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: W, height: H,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("failed to create context\n".data(using: .utf8)!)
    exit(1)
}
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// 背景: 上から下へ淡いグラデーション（白 → 薄いブルーグレー）
let bgGrad = CGGradient(colorsSpace: cs,
                        colors: [color(0.98, 0.99, 1.0), color(0.90, 0.93, 0.97)] as CFArray,
                        locations: [0, 1])!
ctx.drawLinearGradient(bgGrad,
                       start: CGPoint(x: 0, y: h),
                       end: CGPoint(x: 0, y: 0), options: [])

// アイコンが置かれる想定位置（左 ~150, 右 ~450、上から 180 → CG座標は下原点なので反転）
// Finder のアイコン座標は左上原点。CG は左下原点。y を反転して合わせる。
let iconY = h - 180          // アイコン中心の CG 上での y
let leftX: CGFloat = 150
let rightX: CGFloat = 450

// 中央の右向き矢印（左アイコンと右アイコンの間）
ctx.saveGState()
let arrowColor = color(0.35, 0.40, 0.50, 0.85)
ctx.setStrokeColor(arrowColor)
ctx.setFillColor(arrowColor)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let ax0 = leftX + 55            // 矢印シャフト開始
let ax1 = rightX - 70           // 矢印シャフト終了（矢じり手前）
let ay = iconY
let shaftW: CGFloat = 10
ctx.setLineWidth(shaftW)
ctx.move(to: CGPoint(x: ax0, y: ay))
ctx.addLine(to: CGPoint(x: ax1, y: ay))
ctx.strokePath()
// 矢じり
let headLen: CGFloat = 26
let headHalf: CGFloat = 20
ctx.move(to: CGPoint(x: ax1 + headLen, y: ay))
ctx.addLine(to: CGPoint(x: ax1 - 4, y: ay + headHalf))
ctx.addLine(to: CGPoint(x: ax1 - 4, y: ay - headHalf))
ctx.closePath()
ctx.fillPath()
ctx.restoreGState()

// 案内文を描く（CoreText）
func drawCenteredText(_ text: String, cx: CGFloat, cy: CGFloat, fontSize: CGFloat,
                      textColor: CGColor) {
    let font = CTFontCreateUIFontForLanguage(.system, fontSize, "ja" as CFString)
        ?? CTFontCreateWithName("HiraginoSans-W6" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: textColor,
    ]
    let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let tx = cx - bounds.width / 2 - bounds.minX
    let ty = cy - bounds.height / 2 - bounds.minY
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: tx, y: ty)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// 見出し（矢印の少し上）
drawCenteredText("ドラッグして「アプリケーション」へ",
                 cx: w / 2, cy: iconY + 70, fontSize: 22,
                 textColor: color(0.20, 0.24, 0.32))
// 補助文（下部）
drawCenteredText("ドラッグしてインストール",
                 cx: w / 2, cy: 60, fontSize: 15,
                 textColor: color(0.45, 0.50, 0.58))

guard let img = ctx.makeImage() else {
    FileHandle.standardError.write("failed to make image\n".data(using: .utf8)!)
    exit(1)
}
let url = URL(fileURLWithPath: outPath) as CFURL
guard let dst = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write("failed to create png destination\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dst, img, nil)
if !CGImageDestinationFinalize(dst) {
    FileHandle.standardError.write("failed to finalize png\n".data(using: .utf8)!)
    exit(1)
}
print("wrote dmg background -> \(outPath) (\(W)x\(H))")
