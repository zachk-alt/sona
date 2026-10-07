import Foundation
import CoreGraphics

/// Pure placement across Quartz window coordinates and AppKit display frames.
/// The returned origin and panelSize include the glow outside the inset glass.
enum AssistantPanelPlacement {
    struct Display {
        let quartzFrame:CGRect
        let frame:CGRect
        let visibleFrame:CGRect
    }

    /// Dictation still prefers its menu item, but a missing or overflowed
    /// item must never put the recording surface outside a usable display.
    static func recordingOrigin(displays:[Display],menuAnchor:CGRect?,fallbackFrame:CGRect?,
        panelSize:CGSize,glowMargin:CGFloat=26) -> CGPoint? {
        let screens=displays.filter { usable($0.quartzFrame) && usable($0.frame)
            && usable($0.visibleFrame) && $0.frame.contains($0.visibleFrame) }
        guard !screens.isEmpty else { return nil }
        let anchorIndex=menuAnchor.flatMap { usable($0) ? greatestIntersection($0,frames:screens.map(\.frame)) : nil }
        let fallbackIndex=fallbackFrame.flatMap { usable($0) ? greatestIntersection($0,frames:screens.map(\.frame)) : nil }
        let display=screens[anchorIndex ?? fallbackIndex ?? 0]
        return origin(target:display.quartzFrame,displays:screens,menuAnchor:menuAnchor,
                      panelSize:panelSize,glowMargin:glowMargin)
    }

    static func origin(target:CGRect,displays:[Display],menuAnchor:CGRect?,panelSize:CGSize,
        glowMargin:CGFloat=26) -> CGPoint? {
        guard usable(target), panelSize.width.isFinite, panelSize.height.isFinite,
              glowMargin.isFinite, glowMargin >= 0 else { return nil }
        let glassWidth=panelSize.width-2*glowMargin, glassHeight=panelSize.height-2*glowMargin
        guard glassWidth.isFinite, glassHeight.isFinite, glassWidth > 0, glassHeight > 0 else { return nil }
        let screens=displays.filter {
            usable($0.quartzFrame) && usable($0.frame) && usable($0.visibleFrame)
                && $0.frame.contains($0.visibleFrame)
        }
        guard let targetIndex=greatestIntersection(target,frames:screens.map(\.quartzFrame)) else { return nil }
        let screen=screens[targetIndex], visible=screen.visibleFrame
        let minGlassX=visible.minX+8, maxGlassX=visible.maxX-8-glassWidth
        let minGlassTop=visible.minY+8+glassHeight, maxGlassTop=visible.maxY-6
        guard minGlassX <= maxGlassX, minGlassTop <= maxGlassTop else { return nil }

        var center=screen.frame.maxX-180, top=maxGlassTop
        if let anchor=menuAnchor, usable(anchor),
           let sourceIndex=greatestIntersection(anchor,frames:screens.map(\.frame)) {
            if sourceIndex == targetIndex {
                center=anchor.midX
                top=anchor.minY-6
            } else {
                center=screen.frame.maxX-(screens[sourceIndex].frame.maxX-anchor.midX)
            }
        }
        let glassX=min(maxGlassX,max(minGlassX,center-glassWidth/2))
        let glassTop=min(maxGlassTop,max(minGlassTop,top))
        let result=CGPoint(x:glassX-glowMargin,y:glassTop-glassHeight-glowMargin)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    private static func usable(_ rect:CGRect) -> Bool {
        rect.size.width > 0 && rect.size.height > 0
            && [rect.origin.x,rect.origin.y,rect.size.width,rect.size.height,rect.maxX,rect.maxY].allSatisfy(\.isFinite)
    }
    private static func greatestIntersection(_ rect:CGRect,frames:[CGRect]) -> Int? {
        var best:Int?, area:CGFloat=0
        for (index,frame) in frames.enumerated() {
            let intersection=rect.intersection(frame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }
            let candidate=intersection.width*intersection.height
            guard candidate.isFinite, candidate > area else { continue }
            best=index; area=candidate
        }
        return best
    }
}
