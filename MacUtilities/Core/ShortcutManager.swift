import AppKit
import Carbon.HIToolbox
import Observation

/// Идентификатор действия, которому назначается горячая клавиша.
struct ShortcutID: Hashable, RawRepresentable, Codable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    static let clipboardPanel = ShortcutID("clipboard.panel")
    static let switcherForward = ShortcutID("switcher.forward")
    static let switcherBackward = ShortcutID("switcher.backward")
    static let dockPreviewPanel = ShortcutID("dockPreview.panel")
    static let screenshotCapture = ShortcutID("screenshot.capture")
}

enum ShortcutStatus: Equatable {
    case notSet
    case inactive                 // модуль выключен — сочетание не зарегистрировано
    case registered
    case conflict(String)         // уже занято другим действием этого приложения
    case systemReserved(String)   // известное системное сочетание macOS
    case invalid                  // нет модификаторов
    case failed(Int32)            // ошибка RegisterEventHotKey

    var isProblem: Bool {
        switch self {
        case .conflict, .systemReserved, .invalid, .failed: return true
        default: return false
        }
    }

    var message: String {
        switch self {
        case .notSet: return "Не назначено"
        case .inactive: return "Неактивно (модуль выключен)"
        case .registered: return "Активно"
        case .conflict(let other): return "Конфликт: уже используется для «\(other)»"
        case .systemReserved(let name): return "Занято системой: \(name)"
        case .invalid: return "Нужен хотя бы один модификатор ⌘, ⌥ или ⌃"
        case .failed(let code): return "Не удалось зарегистрировать (код \(code))"
        }
    }
}

/// Глобальные горячие клавиши через Carbon `RegisterEventHotKey`.
///
/// Почему Carbon: это единственный публичный API регистрации глобальных сочетаний,
/// не требующий разрешений Accessibility / Input Monitoring и не перехватывающий
/// все нажатия клавиатуры (в отличие от CGEventTap). Обработчик ставится один раз
/// на всё приложение, повторная регистрация того же сочетания ничего не делает.
@MainActor
@Observable
final class ShortcutManager {
    private struct Declaration {
        var title: String
        var combo: KeyCombo?
        var active: Bool
        var handler: () -> Void
    }

    private struct Registration {
        var combo: KeyCombo
        var carbonID: UInt32
        var ref: EventHotKeyRef
    }

    private(set) var statuses: [ShortcutID: ShortcutStatus] = [:]

    @ObservationIgnored private var declarations: [ShortcutID: Declaration] = [:]
    @ObservationIgnored private var registrations: [ShortcutID: Registration] = [:]
    @ObservationIgnored private var idsByCarbonID: [UInt32: ShortcutID] = [:]
    @ObservationIgnored private var nextCarbonID: UInt32 = 1
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private let signature: OSType = 0x4D4D_544C // 'MMTL'

    /// Пока пользователь записывает новое сочетание, все регистрации Carbon снимаются:
    /// иначе уже назначенное сочетание перехватывалось бы до поля записи.
    @ObservationIgnored var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended {
                for id in Array(registrations.keys) { unregister(id) }
            } else {
                reconcileAll()
            }
        }
    }

    init() {}

    func status(for id: ShortcutID) -> ShortcutStatus {
        statuses[id] ?? .notSet
    }

    // MARK: - Public API

    /// Объявляет (или обновляет) сочетание. Вызывается модулем при запуске, остановке
    /// и при каждом изменении настроек. Если ничего не изменилось — повторной регистрации нет.
    func update(_ id: ShortcutID, title: String, combo: KeyCombo?, active: Bool, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        declarations[id] = Declaration(title: title, combo: combo, active: active, handler: handler)
        reconcileAll()
    }

    func deactivate(_ id: ShortcutID) {
        guard var declaration = declarations[id] else { return }
        declaration.active = false
        declarations[id] = declaration
        reconcileAll()
    }

    /// Возвращает название действия, которое уже использует это сочетание (кроме `id`).
    func conflictingTitle(for combo: KeyCombo, excluding id: ShortcutID) -> String? {
        for (otherID, declaration) in declarations where otherID != id && declaration.combo == combo {
            return declaration.title
        }
        return nil
    }

    func unregisterAll() {
        for id in Array(registrations.keys) { unregister(id) }
        for id in declarations.keys { declarations[id]?.active = false }
        reconcileAll()
    }

    // MARK: - Reconcile

    /// Приводит фактические регистрации Carbon в соответствие с объявлениями.
    /// При конфликте двух активных действий регистрируется то, чей идентификатор
    /// меньше лексикографически (детерминированно), второе получает статус `.conflict`.
    private func reconcileAll() {
        var newStatuses: [ShortcutID: ShortcutStatus] = [:]
        var claimed: [KeyCombo: ShortcutID] = [:]

        for id in declarations.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let declaration = declarations[id] else { continue }
            guard let combo = declaration.combo else {
                unregister(id)
                newStatuses[id] = .notSet
                continue
            }
            if !combo.isValidGlobalShortcut {
                unregister(id)
                newStatuses[id] = .invalid
                continue
            }
            if let system = KeyCombo.knownSystemShortcuts[combo] {
                unregister(id)
                newStatuses[id] = .systemReserved(system)
                continue
            }
            if let owner = claimed[combo] ?? conflictingDeclaration(combo, before: id) {
                unregister(id)
                newStatuses[id] = .conflict(declarations[owner]?.title ?? owner.rawValue)
                continue
            }
            guard declaration.active else {
                unregister(id)
                newStatuses[id] = .inactive
                continue
            }
            claimed[combo] = id
            newStatuses[id] = isSuspended ? .registered : register(id, combo: combo)
        }
        if newStatuses != statuses { statuses = newStatuses }
    }

    /// Конфликт с объявлением, которое обрабатывается раньше (даже если оно неактивно),
    /// чтобы пользователь видел конфликт ещё до включения второго модуля.
    private func conflictingDeclaration(_ combo: KeyCombo, before id: ShortcutID) -> ShortcutID? {
        declarations.first { otherID, declaration in
            otherID.rawValue < id.rawValue && declaration.combo == combo
        }?.key
    }

    private func register(_ id: ShortcutID, combo: KeyCombo) -> ShortcutStatus {
        if let existing = registrations[id] {
            if existing.combo == combo { return .registered }
            unregister(id)
        }
        let carbonID = nextCarbonID
        nextCarbonID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: carbonID)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.shortcuts.error("RegisterEventHotKey failed for \(id.rawValue, privacy: .public): \(status)")
            return .failed(status)
        }
        registrations[id] = Registration(combo: combo, carbonID: carbonID, ref: ref)
        idsByCarbonID[carbonID] = id
        Log.shortcuts.info("Registered \(combo.displayString, privacy: .public) for \(id.rawValue, privacy: .public)")
        return .registered
    }

    private func unregister(_ id: ShortcutID) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.ref)
        idsByCarbonID[registration.carbonID] = nil
        Log.shortcuts.info("Unregistered \(id.rawValue, privacy: .public)")
    }

    // MARK: - Временные сочетания

    @ObservationIgnored private var temporary: [UInt32: (ref: EventHotKeyRef, combo: KeyCombo, handler: (KeyCombo) -> Void)] = [:]

    /// Регистрирует сочетания только на время показа оверлея (например, стрелки и Esc
    /// в переключателе окон). Не участвуют в проверке конфликтов и не сохраняются.
    /// Возвращает токены для `unregisterTemporary`.
    func registerTemporary(_ combos: [KeyCombo], handler: @escaping (KeyCombo) -> Void) -> [UInt32] {
        installHandlerIfNeeded()
        var tokens: [UInt32] = []
        for combo in Set(combos) {
            let carbonID = nextCarbonID
            nextCarbonID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                             EventHotKeyID(signature: signature, id: carbonID),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                temporary[carbonID] = (ref, combo, handler)
                tokens.append(carbonID)
            }
        }
        return tokens
    }

    func unregisterTemporary(_ tokens: [UInt32]) {
        for token in tokens {
            if let entry = temporary.removeValue(forKey: token) {
                UnregisterEventHotKey(entry.ref)
            }
        }
    }

    // MARK: - Carbon event handler

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr else { return result }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon вызывает обработчик на главном потоке (через главный run loop).
            MainActor.assumeIsolated {
                manager.handleHotKey(carbonID: hotKeyID.id, signature: hotKeyID.signature)
            }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandler)
        if status != noErr {
            Log.shortcuts.error("InstallEventHandler failed: \(status)")
        }
    }

    private func handleHotKey(carbonID: UInt32, signature: OSType) {
        guard signature == self.signature else { return }
        if let entry = temporary[carbonID] {
            entry.handler(entry.combo)
            return
        }
        guard !isSuspended,
              let id = idsByCarbonID[carbonID],
              let declaration = declarations[id], declaration.active else { return }
        declaration.handler()
    }
}
