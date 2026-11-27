// pv60 <ms> <pid>: records every window of <pid> with ScreenCaptureKit at 60 fps (only those windows, nothing else on screen) and prints, per frame change, how many columns hold a visible pixel
import ScreenCaptureKit
import AppKit
import CoreMedia
import CoreVideo
import Foundation
let a = CommandLine.arguments; let ms = Double(a[1])!; let pid = Int32(a[2])!
final class Out: NSObject, SCStreamOutput {
    let name: String; let t0: Date; var last = ""
    init(_ n: String, _ t: Date) { name = n; t0 = t }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), bpr = CVPixelBufferGetBytesPerRow(px)
        let p = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self); var n = 0, lo = w, hi = -1
        for x in stride(from: 0, to: w, by: 2) { var vis = false; for y in stride(from: 0, to: h, by: 16) where p[y * bpr + x * 4 + 3] > 25 { vis = true; break }
            if vis { n += 1; lo = min(lo, x); hi = max(hi, x) } }
        let s = "\(name) \(w)px visible cols \(n * 2) [\(lo)...\(hi)]"
        if s != last { print(String(format: "%7.1f %@", Date().timeIntervalSince(t0) * 1000, s)); last = s; fflush(stdout) }
    }
}
_ = NSApplication.shared
let t0 = Date(); var streams: [SCStream] = []; var outs: [Out] = []
let sem = DispatchSemaphore(value: 0)
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
    guard let content else { print("no content \(String(describing: err))"); sem.signal(); return }
    for win in content.windows where win.owningApplication?.processID == pid && win.frame.width > 60 {
        let f = SCContentFilter(desktopIndependentWindow: win); let c = SCStreamConfiguration()
        c.width = Int(win.frame.width); c.height = Int(win.frame.height); c.minimumFrameInterval = CMTime(value: 1, timescale: 60); c.pixelFormat = kCVPixelFormatType_32BGRA; c.showsCursor = false
        let o = Out("win \(win.windowID)", t0); let s = SCStream(filter: f, configuration: c, delegate: nil)
        try? s.addStreamOutput(o, type: .screen, sampleHandlerQueue: DispatchQueue(label: "q\(win.windowID)"))
        s.startCapture { e in print("start win \(win.windowID) \(e.map { "\($0)" } ?? "ok")"); fflush(stdout) }; streams.append(s); outs.append(o)
    }
    print("windows matched: \(streams.count) of \(content.windows.count)"); fflush(stdout)
    sem.signal()
}
sem.wait()
Thread.sleep(forTimeInterval: ms / 1000)
for s in streams { s.stopCapture { _ in } }
Thread.sleep(forTimeInterval: 0.2)
