import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

struct AssistantScreenImage {
    let mimeType: String
    let dataBase64: String
    let width: Int
    let height: Int
}
struct AssistantWindowReference {
    let pid: pid_t
    let windowID: CGWindowID
    var frame: CGRect? = nil
    static func invocation() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return nil }
        let candidates:[AssistantCapturePolicy.Window] = windows.compactMap { item in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let raw = item[kCGWindowBounds as String] as? [String:Any],
                  let frame = CGRect(dictionaryRepresentation:raw as CFDictionary), AssistantCapturePolicy.usable(frame) else { return nil }
            return .init(id:id,frame:frame)
        }
        let focusedFrame=focusedWindowFrame(pid:app.processIdentifier)
        let accessibilityWindows=AssistantCapturePolicy.needsWindowMetadata(candidates,focusedFrame:focusedFrame)
            ? accessibilityWindowFrames(pid:app.processIdentifier) : nil
        guard let chosen = AssistantCapturePolicy.window(candidates,focusedFrame:focusedFrame,accessibilityWindows:accessibilityWindows),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        return .init(pid:app.processIdentifier,windowID:chosen.id,frame:chosen.frame)
    }
    /// Only queried for an otherwise-selected lower-corner status shape. Read
    /// geometry from at most 16 AX windows, never titles or document values.
    private static func accessibilityWindowFrames(pid:pid_t) -> [CGRect]? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline=ProcessInfo.processInfo.systemUptime+0.1
        let app=AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.01)
        var count:CFIndex=0, values:CFArray?
        guard AXUIElementGetAttributeValueCount(app,kAXWindowsAttribute as CFString,&count) == .success,
              count > 0, count <= 16,
              AXUIElementCopyAttributeValues(app,kAXWindowsAttribute as CFString,0,count,&values) == .success,
              let windows=values as? [AXUIElement], windows.count == count else { return nil }
        var frames:[CGRect]=[]
        func frame(_ window:AXUIElement) -> CGRect? {
            let remaining=deadline-ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(window,Float(min(0.01,remaining)))
            var actual:pid_t=0, attributes:CFArray?
            guard AXUIElementGetPid(window,&actual) == .success, actual == pid,
                  AXUIElementCopyMultipleAttributeValues(window,[kAXPositionAttribute,kAXSizeAttribute] as CFArray,[],&attributes) == .success,
                  let attributes=attributes as? [AnyObject], attributes.count == 2,
                  CFGetTypeID(attributes[0]) == AXValueGetTypeID(), CFGetTypeID(attributes[1]) == AXValueGetTypeID() else { return nil }
            var point=CGPoint.zero, size=CGSize.zero
            guard AXValueGetValue(attributes[0] as! AXValue,.cgPoint,&point), AXValueGetValue(attributes[1] as! AXValue,.cgSize,&size) else { return nil }
            let frame=CGRect(origin:point,size:size)
            return AssistantCapturePolicy.usable(frame) ? frame : nil
        }
        for window in windows {
            guard let value=frame(window) else { return nil }
            frames.append(value)
        }
        // Sheets/popovers may be the focused element's top-level container
        // without appearing as a separate AXWindows entry. Preserve that frame.
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var focused:CFTypeRef?, top:CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element=focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element,0.01)
        guard AXUIElementCopyAttributeValue(element,kAXTopLevelUIElementAttribute as CFString,&top) == .success,
              let top, CFGetTypeID(top) == AXUIElementGetTypeID(), let topFrame=frame(top as! AXUIElement),
              ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return AssistantCapturePolicy.completeWindowFrames(frames,focusedTopLevel:topFrame)
    }
    private static func focusedWindowFrame(pid:pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.03)
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        var owner:pid_t = 0
        guard AXUIElementGetPid(window,&owner) == .success, owner == pid else { return nil }
        AXUIElementSetMessagingTimeout(window,0.03)
        var positionValue:CFTypeRef?, sizeValue:CFTypeRef?
        guard AXUIElementCopyAttributeValue(window,kAXPositionAttribute as CFString,&positionValue) == .success,
              AXUIElementCopyAttributeValue(window,kAXSizeAttribute as CFString,&sizeValue) == .success,
              let positionValue, let sizeValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue,.cgPoint,&position),
              AXValueGetValue(sizeValue as! AXValue,.cgSize,&size) else { return nil }
        let frame = CGRect(origin:position,size:size)
        return AssistantCapturePolicy.usable(frame) ? frame : nil
    }
    func remainsForeground() -> Bool { Self.invocation().map { $0.pid == pid && $0.windowID == windowID && (frame == nil || $0.frame == frame) } == true }
}

/// Single selected-window screenshot, retained only in memory for this request.
/// This type has no startup hook, timer, stream, file URL, or background capture.
@MainActor
final class AssistantScreenCapture {
    enum Failure: LocalizedError {
        case permission, changedWindow, unavailable, excessive, protected
        var errorDescription: String? {
            switch self {
            case .permission: return "Allow Screen Recording for Sona in System Settings, then invoke Assistant again."
            case .changedWindow: return "The foreground window changed. Invoke Assistant again on the window you want to use."
            case .unavailable: return "This window could not be captured. No screen image was sent."
            case .excessive: return "The screen image exceeded the request limit. No image was sent."
            case .protected: return "Assistant is unavailable in a protected field. No screen image was sent."
            }
        }
    }
    static func permissionForExplicitAction() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        _ = CGRequestScreenCaptureAccess(); return false
    }
    func captureExplicitAction(_ target:AssistantWindowReference,timeout:Double = 5) async throws -> AssistantScreenImage {
        guard target.remainsForeground(), !Task.isCancelled else { throw Failure.changedWindow }
        // Only the explicit invocation requests permission. A later action
        // capture fails if revoked instead of reopening the permission prompt.
        guard CGPreflightScreenCaptureAccess() else { throw Failure.permission }
        try rejectProtectedFocus(target)
        guard timeout > 0 else { throw Failure.unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + min(5,timeout)
        while true {
            guard target.remainsForeground(), !Task.isCancelled else { throw Failure.changedWindow }
            try rejectProtectedFocus(target)
            guard CGPreflightScreenCaptureAccess() else { throw Failure.permission }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.unavailable }
            do { return try await captureReadyWindow(target,deadline:deadline) }
            catch let failure as Failure {
                guard failure == .unavailable else { throw failure }
            } catch {
                guard !Task.isCancelled, target.remainsForeground() else { throw Failure.changedWindow }
            }
            guard deadline - ProcessInfo.processInfo.systemUptime > 0.15 else { throw Failure.unavailable }
            try await Task.sleep(for:.milliseconds(150))
        }
    }
    private func captureReadyWindow(_ target:AssistantWindowReference,deadline:Double) async throws -> AssistantScreenImage {
        let budget = deadline - ProcessInfo.processInfo.systemUptime
        guard budget > 0 else { throw Failure.unavailable }
        let content = try await AssistantCaptureDeadline<SCShareableContent>().wait(seconds:budget) { completion in
            SCShareableContent.getExcludingDesktopWindows(true,onScreenWindowsOnly:true) { content,error in
                if let content { completion(.success(content)) }
                else { completion(.failure(error ?? Failure.unavailable)) }
            }
        }
        guard target.remainsForeground(), !Task.isCancelled else { throw Failure.changedWindow }
        guard let window = content.windows.first(where:{$0.windowID == target.windowID && $0.owningApplication?.processID == target.pid}),
              window.frame.width > 1, window.frame.height > 1 else { throw Failure.unavailable }
        guard let expected=target.frame, AssistantCapturePolicy.captureFrameMatches(expected,window.frame) else {
            Log.write("assistant: capture_geometry_mismatch")
            throw Failure.unavailable
        }
        try rejectProtectedFocus(target)
        let filter = SCContentFilter(desktopIndependentWindow:window)
        let configuration = SCStreamConfiguration()
        guard let pixels = AssistantCapturePolicy.pixels(points:window.frame.size,pixelsPerPoint:Double(filter.pointPixelScale)) else { throw Failure.excessive }
        configuration.width = pixels.width; configuration.height = pixels.height
        configuration.captureResolution = .best
        configuration.showsCursor = false; configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true; configuration.scalesToFit = true
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, !Task.isCancelled else { throw Failure.unavailable }
        let image = try await AssistantCaptureDeadline<CGImage>().wait(seconds:remaining) { completion in
            SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration) { image,error in
                if let image { completion(.success(image)) }
                else { completion(.failure(error ?? Failure.unavailable)) }
            }
        }
        guard target.remainsForeground(), !Task.isCancelled else { throw Failure.changedWindow }
        try rejectProtectedFocus(target)
        guard image.width == pixels.width, image.height == pixels.height,
              image.width * image.height <= AssistantCapturePolicy.maximumPixels else { throw Failure.excessive }
        // Re-encode this one in-memory image only. No second capture or model
        // request, and no weakening of the existing 2 MiB request limit.
        for quality in AssistantCapturePolicy.jpegQualities {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.unavailable }
            guard !Task.isCancelled, target.remainsForeground() else { throw Failure.changedWindow }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw Failure.unavailable }
            CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.unavailable }
            if data.length <= AssistantCapturePolicy.maximumBytes {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.unavailable }
                guard !Task.isCancelled, target.remainsForeground() else { throw Failure.changedWindow }
                try rejectProtectedFocus(target)
                guard CGPreflightScreenCaptureAccess() else { throw Failure.permission }
                return .init(mimeType:"image/jpeg",dataBase64:(data as Data).base64EncodedString(),width:image.width,height:image.height)
            }
        }
        throw Failure.excessive
    }
    private func rejectProtectedFocus(_ target:AssistantWindowReference) throws {
        guard target.remainsForeground() else { throw Failure.changedWindow }
        let app = AXUIElementCreateApplication(target.pid); AXUIElementSetMessagingTimeout(app,0.05)
        var value:CFTypeRef?
        if AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement; AXUIElementSetMessagingTimeout(element,0.05)
            var subrole:CFTypeRef?
            if AXUIElementCopyAttributeValue(element,kAXSubroleAttribute as CFString,&subrole) == .success,
               subrole as? String == "AXSecureTextField" { throw Failure.protected }
        }
    }
}
