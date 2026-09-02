import AppKit
guard CommandLine.arguments.count > 1 else { exit(2) }
let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("cannot load"); exit(1) }
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let data = ctx.data else { print("no data"); exit(1) }
let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let xc = min(max(x, 0), w - 1), yc = min(max(y, 0), h - 1)
    let idx = (yc * w + xc) * 4
    return (Int(buf[idx]), Int(buf[idx + 1]), Int(buf[idx + 2]))
}
print("size: \(w)x\(h)")
var counts: [String: Int] = [:]
var firstPts: [String: [Int]] = [:]
for y in stride(from: 0, to: h, by: 4) {
    for x in stride(from: 0, to: w, by: 4) {
        let (r, g, b) = px(x, y)
        let mx = max(r, g, b), mn = min(r, g, b)
        if mx - mn > 55 && mx > 90 {
            let key = "\(r / 32)-\(g / 32)-\(b / 32)"
            counts[key, default: 0] += 1
            if firstPts[key] == nil { firstPts[key] = [x, y] }
        }
    }
}
let sorted = counts.sorted { $0.value > $1.value }.prefix(14)
for (k, v) in sorted {
    print("cluster \(k) n=\(v) first=\(firstPts[k]!)")
}
