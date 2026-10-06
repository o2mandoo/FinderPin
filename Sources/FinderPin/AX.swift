import AppKit
import ApplicationServices

/// AXUIElement → CGWindowID. Private, but exported from HIServices and used by
/// AltTab/Rectangle/yabai; works with SIP enabled.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? { value(e, name) as? String }
    static func bool(_ e: AXUIElement, _ name: String) -> Bool? { value(e, name) as? Bool }
    static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] { (value(e, name) as? [AXUIElement]) ?? [] }
    static func children(_ e: AXUIElement) -> [AXUIElement] { elements(e, kAXChildrenAttribute) }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func windowID(_ e: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(e, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    @discardableResult
    static func set(_ e: AXUIElement, _ name: String, _ v: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(e, name as CFString, v)
    }

    @discardableResult
    static func perform(_ e: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(e, action as CFString)
    }

    /// Breadth-first search for a role, without descending into large content
    /// containers (list rows etc.) so the check stays cheap.
    static func containsRole(_ role: String, in root: AXUIElement, maxDepth: Int) -> Bool {
        let opaque: Set<String> = ["AXOutline", "AXTable", "AXList", "AXRow"]
        var level = [root]
        for _ in 0..<maxDepth {
            var next: [AXUIElement] = []
            for e in level {
                for c in children(e) {
                    let r = string(c, kAXRoleAttribute) ?? ""
                    if r == role { return true }
                    if !opaque.contains(r) { next.append(c) }
                }
            }
            if next.isEmpty { return false }
            level = next
        }
        return false
    }
}

/// Space membership of windows (SkyLight, read-only; works with SIP enabled).
/// Finder keeps closed windows alive but ordered out, so "the window server still
/// knows this window" does not mean it is open. An open window on another Space
/// belongs to that Space; a closed one belongs to none.
enum WindowSpaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let fns: (MainConnectionFn, CopySpacesFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let conn = dlsym(h, "SLSMainConnectionID"),
              let copy = dlsym(h, "SLSCopySpacesForWindows") else { return nil }
        return (unsafeBitCast(conn, to: MainConnectionFn.self), unsafeBitCast(copy, to: CopySpacesFn.self))
    }()

    /// nil when the API is unavailable.
    static func isOnAnySpace(_ wid: CGWindowID) -> Bool? {
        guard let (conn, copy) = fns else { return nil }
        let spaces = copy(conn(), 0x7, [wid] as CFArray)?.takeRetainedValue() as? [Int] ?? []
        return !spaces.isEmpty
    }
}
