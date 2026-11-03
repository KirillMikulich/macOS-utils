import AppKit
import ApplicationServices

/// Тонкие обёртки над Accessibility API (AXUIElement).
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String, as type: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else {
            return nil
        }
        return value as? T
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name, as: String.self)
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name, as: Bool.self)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        // CFArray из AX всегда содержит AXUIElement; приведение через CFGetTypeID безопасно.
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func point(_ element: AXUIElement, _ name: String = kAXPositionAttribute) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ name: String = kAXSizeAttribute) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element), let size = size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    // MARK: - Сопоставление AX-окна и CGWindowID

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow` — НЕДОКУМЕНТИРОВАННАЯ функция ApplicationServices.
    ///
    /// Обоснование: публичного способа получить CGWindowID для AXUIElement-окна нет,
    /// а он нужен, чтобы сделать миниатюру именно этого окна (ScreenCaptureKit работает
    /// с CGWindowID). Её используют AltTab, DockDoor, Rectangle и др. много лет.
    /// Функция загружается через dlsym: если Apple её уберёт, приложение не упадёт,
    /// а перейдёт на сопоставление по позиции/размеру (`WindowDiscoveryService.matchByFrame`).
    private static let getWindowFunction: GetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            Log.windows.notice("_AXUIElementGetWindow is unavailable, falling back to frame matching")
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    static var hasPrivateWindowIDLookup: Bool { getWindowFunction != nil }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let function = getWindowFunction else { return nil }
        var id: CGWindowID = 0
        return function(element, &id) == .success && id != 0 ? id : nil
    }
}

extension CGRect {
    /// Перевод из координат AX/CoreGraphics (начало в левом верхнем углу главного экрана)
    /// в координаты AppKit (начало в левом нижнем углу главного экрана).
    var flippedToCocoa: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: origin.x, y: primaryHeight - origin.y - height, width: width, height: height)
    }
}
