import Foundation
import Vision
import AppKit

// 用法: ocr_probe <图片路径> [语言，逗号分隔]
let args = CommandLine.arguments
guard args.count >= 2, let image = NSImage(contentsOfFile: args[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("OCR_FAIL: 读不了图"); exit(1)
}
let languages = (args.count >= 3 ? args[2] : "zh-Hans,en").components(separatedBy: ",")
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = languages
request.usesLanguageCorrection = true
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do { try handler.perform([request]) } catch { print("OCR_FAIL: \(error)"); exit(1) }
let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
print("OCR_LINES: \(lines.count)")
print(lines.joined(separator: "\n"))
