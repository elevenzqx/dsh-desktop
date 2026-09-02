// DSH Desktop · 图标生成器（构建期一次性工具，不属于应用本体）
// 用法: icon-gen <输出.png>
import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: icon-gen <out.png>\n".utf8))
    exit(1)
}
let outPath = CommandLine.arguments[1]
let size = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 圆角渐变背景
let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.28, alpha: 1),
    NSColor(calibratedRed: 0.11, green: 0.42, blue: 0.90, alpha: 1),
    NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.92, alpha: 1),
])!
gradient.draw(in: bgPath, angle: -60)

// “终端”窗口
let termRect = NSRect(x: 215, y: 250, width: 594, height: 460)
let termPath = NSBezierPath(roundedRect: termRect, xRadius: 56, yRadius: 56)
NSColor(calibratedWhite: 0.07, alpha: 0.95).setFill()
termPath.fill()

// 提示符 “>”
let chevron = NSBezierPath()
chevron.lineWidth = 46
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.move(to: NSPoint(x: 300, y: 470))
chevron.line(to: NSPoint(x: 430, y: 370))
chevron.line(to: NSPoint(x: 300, y: 270))
NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.55, alpha: 1).setStroke()
chevron.stroke()

// 光标下划线 “_”
let underscore = NSBezierPath()
underscore.lineWidth = 46
underscore.lineCapStyle = .round
underscore.move(to: NSPoint(x: 480, y: 300))
underscore.line(to: NSPoint(x: 726, y: 300))
NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.55, alpha: 1).setStroke()
underscore.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("icon: failed to render\n".utf8))
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: outPath))