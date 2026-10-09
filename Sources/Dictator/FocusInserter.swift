import AppKit
import ApplicationServices
import CoreGraphics

struct FocusSnapshot {
    let pid: pid_t
    let element: AXUIElement
    let role: String
    /// Screen coordinates from Accessibility, with the origin at the main display's top left.
    let caretRect: CGRect?
}

enum DeliveryResult: Equatable {
    case inserted, copiedFocusChanged, copiedNoAccessibility, copiedPasteUnavailable, copiedPasteUnconfirmed
}

@MainActor
enum FocusInserter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func capture(preferredPID: pid_t? = nil) -> FocusSnapshot? {
        guard isTrusted else { return nil }
        let pid = preferredPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid, pid > 0 else { return nil }
        let application = AXUIElementCreateApplication(pid)
        guard let element = elementAttribute(application, kAXFocusedUIElementAttribute as CFString),
              let role = stringAttribute(element, kAXRoleAttribute as CFString),
              ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"].contains(role) else { return nil }
        return FocusSnapshot(pid: pid, element: element, role: role,
                             caretRect: caretRect(in: element))
    }

    static func deliver(_ text: String, to target: FocusSnapshot?) async throws -> DeliveryResult {
        try Task.checkCancellation()
        guard isTrusted else { copy(text); return .copiedNoAccessibility }
        guard let target, let current = capture(), current.pid == target.pid,
              CFEqual(current.element, target.element) else {
            copy(text); return .copiedFocusChanged
        }
        let previousValue = textValue(target.element)
        let pasteboard = NSPasteboard.general
        let old = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let dictationChangeCount = pasteboard.changeCount
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            copy(text)
            return .copiedPasteUnavailable
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(target.pid); up.postToPid(target.pid)
        try? await Task.sleep(for: .milliseconds(400))
        // Never overwrite a clipboard value the user copied while paste was in flight.
        guard pasteboard.changeCount == dictationChangeCount else { return .inserted }
        guard let previousValue, let insertedValue = textValue(target.element),
              insertedValue != previousValue, insertedValue.contains(text) else {
            // Some fields reject synthetic paste or do not expose a readable AX value. Keep the
            // dictation on the clipboard in either case, so the user can paste it manually.
            return .copiedPasteUnconfirmed
        }
        old.restore(to: pasteboard)
        return .inserted
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func textValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value else { return nil }
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        return nil
    }

    private static func caretRect(in element: AXUIElement) -> CGRect? {
        let field = elementRect(element)
        if let selection = axValue(element, kAXSelectedTextRangeAttribute as CFString),
           AXValueGetType(selection) == .cfRange {
            var range = CFRange()
            if AXValueGetValue(selection, .cfRange, &range) {
                let offset = range.location + range.length
                let textLength = textValue(element)?.utf16.count ?? 0
                if offset >= 0,
                   let rect = bounds(in: element, at: offset, length: 0),
                   plausibleTextRect(rect, field: field, maxWidth: 8, empty: textLength == 0) {
                    return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
                }
                if offset >= 0, offset < textLength,
                   let next = bounds(in: element, at: offset, length: 1),
                   plausibleTextRect(next, field: field, maxWidth: 100, empty: false) {
                    return CGRect(x: next.minX, y: next.minY, width: 1, height: next.height)
                }
                if offset > 0,
                   let previous = bounds(in: element, at: offset - 1, length: 1),
                   plausibleTextRect(previous, field: field, maxWidth: 100, empty: false) {
                    return CGRect(x: previous.maxX, y: previous.minY, width: 1, height: previous.height)
                }
            }
        }
        // Chromium, Electron and WebKit editors often reject the range query for a caret but
        // answer the text-marker one, which is what their own caret drawing uses.
        if let rect = markerCaretRect(in: element),
           plausibleTextRect(rect, field: field, maxWidth: 8, empty: false) {
            return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
        }
        guard let field else { return nil }
        // Empty editors often report the whole field for a zero-length range. Use the leading
        // text inset, not the field midpoint, so the indicator stays above the insertion line.
        let xInset = min(24, max(10, field.width * 0.05))
        let yInset = min(32, max(8, field.height * 0.15))
        return CGRect(x: field.minX + xInset, y: field.minY + yInset,
                      width: 1, height: min(24, max(1, field.height - yInset)))
    }

    private static func plausibleTextRect(_ rect: CGRect, field: CGRect?,
                                          maxWidth: CGFloat, empty: Bool) -> Bool {
        guard rect.height >= 4, rect.height <= 80, rect.width >= 0, rect.width <= maxWidth else {
            return false
        }
        guard let field else { return true }
        guard rect.minX >= field.minX - 8, rect.minX <= field.maxX + 8,
              rect.minY >= field.minY - 8, rect.maxY <= field.maxY + 8 else { return false }
        if empty, field.width > 160,
           rect.minX > field.minX + min(100, field.width * 0.25) { return false }
        return true
    }

    private static func bounds(in element: AXUIElement, at location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result
        ) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private static func markerCaretRect(in element: AXUIElement) -> CGRect? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success,
              let marker else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, marker, &result
        ) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private static func elementRect(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute as CFString),
              let size = axValue(element, kAXSizeAttribute as CFString) else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: CFString) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        return axValue
    }
}

private struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]
    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
