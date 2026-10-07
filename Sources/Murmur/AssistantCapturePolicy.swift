import Foundation
import CoreGraphics

/// Window ordering and pixel limits only. This policy never reads window content.
enum AssistantCapturePolicy {
    struct Window: Equatable { let id:UInt32; let frame:CGRect }
    struct Pixels: Equatable { let width:Int; let height:Int }
    static let maximumEdge = 2560
    static let maximumPixels = maximumEdge * maximumEdge
    static let maximumBytes = 2 * 1024 * 1024
    static let jpegQualities: [Double] = [0.88, 0.76, 0.64, 0.52]

    static func usable(_ frame:CGRect) -> Bool {
        frame.width > 1 && frame.height > 1 && [frame.minX,frame.minY,frame.width,frame.height].allSatisfy(\.isFinite)
    }

    private static func shallowStripShape(_ frame:CGRect) -> Bool {
        // Chrome can place separate full-width toolbars ahead of its content
        // window in CGWindow order. Small ordinary dialogs are not strips.
        frame.width >= 640 && frame.height <= 160 && frame.width / frame.height >= 5
    }

    private static func firstBody(_ windows:[Window]) -> Int? {
        windows.indices.first { index in
            let strip = windows[index].frame
            guard shallowStripShape(strip) else { return true }
            // Geometry alone is not enough: a short dialog must never cause
            // capture of a larger window behind it. A toolbar must also span
            // a later body and sit in that body's adjoining top-edge band.
            let belongsToBody = windows.dropFirst(index+1).contains { candidate in
                let body = candidate.frame
                return body.height > 160 && abs(strip.minX-body.minX) <= 2 && abs(strip.width-body.width) <= 2
                    && strip.minY >= body.minY-160 && strip.minY < body.minY-2 && strip.maxY <= body.minY+160
            }
            return !belongsToBody
        }
    }

    /// Chrome's link status bubble can be a normal-layer CG window. This is
    /// only a suspicious shape, never sufficient proof to skip a window.
    private static func lowerCorner(_ strip:CGRect,of body:CGRect) -> Bool {
        strip.height <= 32 && strip.width <= 480 && strip.width/strip.height >= 4
            && body.width >= 640 && body.height >= 240 && strip.width <= body.width/2
            && abs(strip.maxY-body.maxY) <= 2 && strip.minY > body.minY
            && strip.minX >= body.minX-2 && strip.maxX <= body.maxX+2
            && (abs(strip.minX-body.minX) <= 2 || abs(strip.maxX-body.maxX) <= 2)
    }
    static func matchesFrame(_ first:CGRect,_ second:CGRect) -> Bool {
        usable(first) && usable(second) && abs(first.minX-second.minX) <= 2
            && abs(first.minY-second.minY) <= 2 && abs(first.width-second.width) <= 2
            && abs(first.height-second.height) <= 2
    }
    static func captureFrameMatches(_ retained:CGRect,_ captured:CGRect) -> Bool {
        usable(retained) && usable(captured) && retained == captured
    }
    static func completeWindowFrames(_ windows:[CGRect]?,focusedTopLevel:CGRect?) -> [CGRect]? {
        guard let windows, !windows.isEmpty, windows.count <= 16, windows.allSatisfy(usable),
              let focusedTopLevel, usable(focusedTopLevel) else { return nil }
        return windows+[focusedTopLevel]
    }
    private static func suspiciousIndex(_ windows:[Window]) -> Int? {
        guard let index=firstBody(windows), windows.dropFirst(index+1).contains(where:{ lowerCorner(windows[index].frame,of:$0.frame) }) else { return nil }
        return index
    }
    static func needsWindowMetadata(_ ordered:[Window],focusedFrame:CGRect?) -> Bool {
        let windows=ordered.filter { usable($0.frame) }
        guard let focusedFrame, usable(focusedFrame), let index=suspiciousIndex(windows) else { return false }
        return !matchesFrame(windows[index].frame,focusedFrame)
    }
    private static func focusedBody(_ windows:[Window],focused:CGRect) -> Int? {
        let exact=windows.indices.filter { matchesFrame(windows[$0].frame,focused) }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        // Full-screen Chromium may expose an outer AX frame and a CG content
        // window below separate toolbar windows. Require the actual toolbar
        // band and a unique body, not arbitrary rectangle containment.
        let candidates=windows.indices.filter { index in
            let body=windows[index].frame, header=body.minY-focused.minY
            guard body.width >= 640, body.height >= 240, header > 2, header <= 160,
                  abs(body.minX-focused.minX) <= 2, abs(body.width-focused.width) <= 2,
                  abs(body.maxY-focused.maxY) <= 2 else { return false }
            return windows.prefix(index).contains { toolbar in
                let strip=toolbar.frame
                return shallowStripShape(strip) && abs(strip.minX-focused.minX) <= 2
                    && abs(strip.width-focused.width) <= 2 && abs(strip.minY-focused.minY) <= 2
                    && strip.maxY >= body.minY-2 && strip.maxY <= body.minY+160
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func window(_ ordered:[Window],focusedFrame:CGRect?,accessibilityWindows:[CGRect]?=nil) -> Window? {
        var windows = ordered.filter { usable($0.frame) }
        while let index=suspiciousIndex(windows) {
            let strip=windows[index].frame
            // An actual focused/listed tiny window is a valid dialog or popup.
            if focusedFrame.map({ matchesFrame(strip,$0) }) == true
                || accessibilityWindows?.contains(where:{ matchesFrame(strip,$0) }) == true { break }
            guard let focusedFrame, let accessibilityWindows,
                  accessibilityWindows.contains(where:{ matchesFrame(focusedFrame,$0) }),
                  let body=focusedBody(windows,focused:focusedFrame), body > index,
                  lowerCorner(strip,of:windows[body].frame) else { return nil }
            windows.remove(at:index)
        }
        let firstBody = firstBody(windows)
        if let focusedFrame, usable(focusedFrame), let match = windows.firstIndex(where: {
            abs($0.frame.minX-focusedFrame.minX) <= 2 && abs($0.frame.minY-focusedFrame.minY) <= 2
                && abs($0.frame.width-focusedFrame.width) <= 2 && abs($0.frame.height-focusedFrame.height) <= 2
        }) {
            // A front dialog must win even when AX still identifies its parent.
            // AX can also prove that a genuinely shallow front window is focused.
            if let firstBody, firstBody < match, !windows.allSatisfy({ shallowStripShape($0.frame) }) { return windows[firstBody] }
            return windows[match]
        }
        guard let firstBody, !windows.allSatisfy({ shallowStripShape($0.frame) }) else { return nil }
        return windows[firstBody]
    }

    static func pixels(points:CGSize,pixelsPerPoint:Double) -> Pixels? {
        guard points.width > 1, points.height > 1, points.width.isFinite, points.height.isFinite,
              pixelsPerPoint.isFinite, pixelsPerPoint > 0 else { return nil }
        // Apply one uniform scale to the entire window. No crop, padding or
        // change to normalized click coordinates, only integer-pixel rounding.
        let scale = min(pixelsPerPoint,Double(maximumEdge) / max(points.width,points.height))
        let width = min(maximumEdge,max(1,Int((points.width*scale).rounded())))
        let height = min(maximumEdge,max(1,Int((points.height*scale).rounded())))
        guard width * height <= maximumPixels else { return nil }
        return Pixels(width:width,height:height)
    }
}
