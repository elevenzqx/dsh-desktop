// 临时验证工具：列出 DSHDesktop 的窗口（bounds / 全屏 / 标题），无需屏幕录制权限
import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionAll]
if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        if owner.contains("DSHDesktop") {
            let name = w[kCGWindowName as String] as? String ?? ""
            let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let num = w[kCGWindowNumber as String] as? Int ?? -1
            print("window#\(num): name='\(name)' layer=\(layer) alpha=\(String(format: "%.2f", alpha)) onscreen=\(onscreen) bounds=\(bounds)")
        }
    }
    let screen = CGDisplayBounds(CGMainDisplayID())
    print("mainDisplay: \(Int(screen.width))x\(Int(screen.height))")
} else {
    print("no window list")
}