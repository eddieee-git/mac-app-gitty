// 앱 아이콘을 그린다: Resources/AppIcon.icns, docs/icon.png
// 사용: swift scripts/make-icon.swift  (scripts/make-icon.sh가 iconset·icns까지 만든다)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// macOS 아이콘 격자: 1024 캔버스 안에 824 크기의 둥근 사각형
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 아래로 떨어지는 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// git 주황 → 따뜻한 빨강 그라디언트
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors = [
    NSColor(red: 1.00, green: 0.55, blue: 0.24, alpha: 1).cgColor,
    NSColor(red: 0.91, green: 0.27, blue: 0.18, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
// 위쪽 은은한 하이라이트
ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
ctx.fillEllipse(in: CGRect(x: -100, y: 560, width: 1224, height: 700))
ctx.restoreGState()

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        fatalError("symbol \(name) not found")
    }
    return img
}

func draw(_ img: NSImage, centeredAt center: CGPoint, width: CGFloat) {
    let scale = width / img.size.width
    let rect = CGRect(x: center.x - img.size.width * scale / 2, y: center.y - img.size.height * scale / 2,
                      width: img.size.width * scale, height: img.size.height * scale)
    img.draw(in: rect)
}

// 흰 폴더
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.22).cgColor)
draw(symbol("folder.fill", pointSize: 400, weight: .regular, color: .white),
     centeredAt: CGPoint(x: 512, y: 500), width: 600)
ctx.restoreGState()

// 폴더 안의 브랜치 기호
draw(symbol("arrow.triangle.branch", pointSize: 300, weight: .bold,
            color: NSColor(red: 0.93, green: 0.36, blue: 0.20, alpha: 1)),
     centeredAt: CGPoint(x: 512, y: 440), width: 220)

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print(out)
