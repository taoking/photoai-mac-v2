// 画应用图标：深色圆角方底，两张叠着的照片，前面一张是日落山景，右下一颗金色的星（选片）。
// 用法：swift Scripts/make-icon.swift <输出目录>，生成 1024 的 PNG；Scripts/make-icon.sh 再转成 AppIcon.icns。
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
    .appendingPathComponent("icon_1024.png")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// macOS 图标的连续圆角方（近似）：四角用三次曲线，比普通圆角更圆润。
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = radius * 1.28
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    path.move(to: CGPoint(x: minX + r, y: minY))
    path.addLine(to: CGPoint(x: maxX - r, y: minY))
    path.addCurve(to: CGPoint(x: maxX, y: minY + r), control1: CGPoint(x: maxX - r * 0.36, y: minY), control2: CGPoint(x: maxX, y: minY + r * 0.36))
    path.addLine(to: CGPoint(x: maxX, y: maxY - r))
    path.addCurve(to: CGPoint(x: maxX - r, y: maxY), control1: CGPoint(x: maxX, y: maxY - r * 0.36), control2: CGPoint(x: maxX - r * 0.36, y: maxY))
    path.addLine(to: CGPoint(x: minX + r, y: maxY))
    path.addCurve(to: CGPoint(x: minX, y: maxY - r), control1: CGPoint(x: minX + r * 0.36, y: maxY), control2: CGPoint(x: minX, y: maxY - r * 0.36))
    path.addLine(to: CGPoint(x: minX, y: minY + r))
    path.addCurve(to: CGPoint(x: minX + r, y: minY), control1: CGPoint(x: minX, y: minY + r * 0.36), control2: CGPoint(x: minX + r * 0.36, y: minY))
    path.closeSubpath()
    return path
}

func star(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<10 {
        let radius = i.isMultiple(of: 2) ? outer : inner
        let angle = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// 底：图标网格里 824 见方，留出系统的阴影位置。坐标原点在左下。
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = squircle(body, radius: 185)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
context.addPath(bodyPath)
context.setFillColor(color(0x1B2546))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(bodyPath)
context.clip()
context.drawLinearGradient(gradient([color(0x34467E), color(0x141B35)]), start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
// 左上一点光
context.drawRadialGradient(
    gradient([color(0x7F9CFF, 0.35), color(0x7F9CFF, 0)]),
    startCenter: CGPoint(x: 330, y: 820), startRadius: 0, endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: []
)

/// 一张照片：白边框 + 里面的画面。`angle` 是绕卡片中心转的角度（弧度）。
func card(center: CGPoint, width: CGFloat, height: CGFloat, angle: CGFloat, drawPhoto: (CGRect) -> Void) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle)
    let frame = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
    context.addPath(CGPath(roundedRect: frame, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.setFillColor(color(0xF4F6FB))
    context.fillPath()
    context.restoreGState()
    let inset: CGFloat = 26
    let photo = frame.insetBy(dx: inset, dy: inset)
    context.saveGState()
    context.addPath(CGPath(roundedRect: photo, cornerWidth: 10, cornerHeight: 10, transform: nil))
    context.clip()
    drawPhoto(photo)
    context.restoreGState()
    context.restoreGState()
}

// 后面一张：冷色的湖景，向左歪。
card(center: CGPoint(x: 455, y: 560), width: 500, height: 380, angle: 0.16) { rect in
    context.drawLinearGradient(gradient([color(0x9FC6E8), color(0x5D8FC2)]), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.35))
    hill.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.30),
                  control1: CGPoint(x: rect.midX - 60, y: rect.minY + rect.height * 0.62),
                  control2: CGPoint(x: rect.midX + 80, y: rect.minY + rect.height * 0.18))
    hill.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    hill.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    hill.closeSubpath()
    context.addPath(hill)
    context.setFillColor(color(0x2F5A86))
    context.fillPath()
}

// 前面一张：日落和山，向右歪。
card(center: CGPoint(x: 545, y: 455), width: 540, height: 410, angle: -0.10) { rect in
    context.drawLinearGradient(gradient([color(0xFF8A5B), color(0xFFC46B), color(0xFFE3A3)]), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY + rect.height * 0.3), options: [.drawsAfterEndLocation])
    let sun = CGRect(x: rect.midX + 10, y: rect.minY + rect.height * 0.42, width: 120, height: 120)
    context.setFillColor(color(0xFFF6DC))
    context.fillEllipse(in: sun)
    let far = CGMutablePath()
    far.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.30))
    far.addLine(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.62))
    far.addLine(to: CGPoint(x: rect.minX + rect.width * 0.52, y: rect.minY + rect.height * 0.38))
    far.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.minY + rect.height * 0.52))
    far.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.28))
    far.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    far.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    far.closeSubpath()
    context.addPath(far)
    context.setFillColor(color(0xB0546A))
    context.fillPath()
    let near = CGMutablePath()
    near.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.14))
    near.addLine(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.36))
    near.addLine(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.16))
    near.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.40))
    near.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.20))
    near.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    near.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    near.closeSubpath()
    context.addPath(near)
    context.setFillColor(color(0x4A2E5C))
    context.fillPath()
}

// 金色的星：选片打星。
let starCenter = CGPoint(x: 735, y: 300)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.45))
context.addPath(star(center: starCenter, outer: 150, inner: 64))
context.setFillColor(color(0xFFC83D))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(star(center: starCenter, outer: 150, inner: 64))
context.clip()
context.drawLinearGradient(gradient([color(0xFFE27A), color(0xF5A623)]), start: CGPoint(x: 0, y: starCenter.y + 150), end: CGPoint(x: 0, y: starCenter.y - 150), options: [])
context.restoreGState()
context.addPath(star(center: starCenter, outer: 150, inner: 64))
context.setStrokeColor(color(0xFFFFFF, 0.9))
context.setLineWidth(12)
context.setLineJoin(.round)
context.strokePath()
context.restoreGState()

let image = context.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: output)
print(output.path)
