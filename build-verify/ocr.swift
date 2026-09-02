import AppKit
import Vision
guard CommandLine.arguments.count > 1 else { print("usage: ocr <img>"); exit(2) }
guard let img = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("cannot load"); exit(1) }
let req = VNRecognizeTextRequest { r, _ in
    guard let rs = r.results as? [VNRecognizedTextObservation] else { return }
    for o in rs {
        if let t = o.topCandidates(1).first {
            print(String(format: "y=%.2f x=%.2f  %@", 1.0 - o.boundingBox.midY, o.boundingBox.midX, t.string))
        }
    }
}
req.recognitionLevel = .accurate
req.recognitionLanguages = ["zh-Hans", "en-US"]
req.usesLanguageCorrection = true
try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
