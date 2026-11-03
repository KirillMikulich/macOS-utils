import AppKit

/// Настройки колеса мыши (часть настроек модуля «Мышь и Dock»).
struct WheelSettings: Codable, Equatable {
    var isEnabled = false
    /// Плавная прокрутка вместо резких «щелчков».
    var smooth = true
    /// Отдельное направление для мыши (трекпад не затрагивается).
    var reverseVertical = false
    var reverseHorizontal = false
    /// Минимальный шаг одного щелчка колеса, pt.
    var step = 60.0
    /// Множитель скорости.
    var speed = 1.0
    /// Длительность «доката» прокрутки, с.
    var duration = 0.25
    /// Ускорение при быстром вращении колеса: 0 — выкл., 1 — сильное.
    var acceleration = 0.5
    /// Удержание ⌥ временно выключает плавность.
    var optionBypassesSmoothing = true
    /// Посылать события с фазами жеста, как настоящий трекпад.
    var simulateTrackpad = false
    /// Устарело: прямая доставка докатом приложению (CGEvent.postToPid, как в Mos) на macOS 27
    /// прокрутку не доставляет — проверено и на настоящей мыши. Поле оставлено только для
    /// совместимости файла настроек и игнорируется.
    var deliverToOriginalWindow = false
    /// В этих приложениях колесо без плавности (направление всё равно меняется).
    var excludedBundleIDs: [String] = []
    /// Параметры плавности в единицах Mos: минимальный шаг щелчка, множитель пути,
    /// длительность доката (1…5, больше — дольше и мягче).
    var smoothStep = 33.6
    var smoothSpeed = 2.7
    var smoothDuration = 4.35
    /// ⌥ + колесо — быстрая прокрутка (как «рывок» в Mos).
    var fastScrollWithOption = true

    static let smoothStepRange = 10.0...100.0
    static let smoothSpeedRange = 1.0...6.0
    static let smoothDurationRange = 1.0...5.0
    static let fastScrollMultiplier = 3.0

    static let stepRange = 10.0...200.0
    static let speedRange = 0.3...4.0
    static let durationRange = 0.08...0.8
}

/// Перехват колеса мыши через CGEventTap.
///
/// Устроено по тому же принципу, что и Mos:
/// - перехватчик работает в СОБСТВЕННОМ потоке с отдельным run loop — занятость главного
///   потока не отключает его;
/// - щелчок колеса поглощается и превращается в «путь»; кадры анимации идут в такт
///   обновлению экрана (CVDisplayLink) и только пока есть что прокручивать;
/// - каждый кадр — КОПИЯ исходного события колеса с дробным PointDelta и признаком
///   непрерывной прокрутки;
/// - по умолчанию кадры отправляются в сеанс с ТЕКУЩИМИ координатами курсора (иначе macOS
///   переносила бы курсор), а докат обрывается, как только курсор ушёл на другое окно —
///   в том числе другое окно того же приложения;
/// - доставка как в Mos (https://github.com/Caldis/Mos, автор Caldis, CC BY-NC 4.0 —
///   ScrollCore.swift, ScrollDispatchContext.swift): перехват на cgAnnotatedSessionEventTap,
///   где WindowServer уже указал процесс-получатель, и отправка копии события прямо ему
///   (CGEvent.postToPid) с исходными координатами — докат остаётся в исходном окне и панели,
///   курсор не трогается. Запасной путь (получатель не указан) — отправка в сеанс с обрывом
///   доката, когда курсор уходит.
///
/// События трекпада и Magic Mouse (непрерывные) пропускаются без изменений;
/// с ⌘ или ⌃ (масштаб) колесо работает как обычно. Нужен «Универсальный доступ».
final class ScrollWheelInterceptor: @unchecked Sendable {
    /// Метка наших собственных событий, чтобы не перехватывать их повторно.
    private static let marker: Int64 = 0x4F54_5654 // 'OTVT'

    // Общее состояние — под замком (поток перехватчика, кадры дисплея, главный поток).
    private let lock = NSLock()
    private var sharedSettings = WheelSettings()
    private var frontmostBundleID: String?
    /// Ядро плавной прокрутки, перенесённое из Mos (см. MosScrollEngine).
    private var engine = MosScrollEngine()
    /// Копия исходного события и процесс, которому адресована прокрутка.
    private var template: CGEvent?
    private var targetPID: pid_t = 0
    private var lastFrame = CACurrentMediaTime()
    private var gestureActive = false
    /// Идёт анимация (кадры дисплея запущены).
    private var timerRunning = false
    /// Где курсор был при последней проверке окна под ним (проверяем только после сдвига).
    private var lastCheckedCursor = CGPoint(x: -1, y: -1)
    /// Окно, в котором начали крутить (CGWindowID), и его границы (координаты CG).
    private var targetWindow: CGWindowID = 0
    private var targetBounds = CGRect.null
    /// Где курсор был при последнем щелчке колеса. Докат идёт, только пока курсор рядом:
    /// соседняя прокручиваемая область может быть и внутри того же окна (панели VS Code,
    /// колонки браузера), а её границ снаружи не видно.
    private var anchor = CGPoint.zero
    private static let anchorRadius: CGFloat = 40
    /// В исходном событии было указано окно под курсором — можно доставлять напрямую процессу.
    private var directDelivery = false
    /// Поле события «окно под курсором» (kCGMouseEventWindowUnderMousePointer).
    private static let windowUnderPointerField = CGEventField(rawValue: 91)!

    private var displayLink: CVDisplayLink?
    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var activationObserver: NSObjectProtocol?
    private(set) var lastError: String?

    var isRunning: Bool { tap != nil }

    var settings: WheelSettings {
        get { lock.withLock { sharedSettings } }
        set {
            lock.withLock {
                sharedSettings = newValue
                engine.step = newValue.smoothStep
                engine.speed = newValue.smoothSpeed
                engine.transition = MosScrollEngine.transition(forDuration: newValue.smoothDuration)
            }
        }
    }

    // MARK: - Запуск и остановка (главный поток)

    @MainActor
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<ScrollWheelInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }
        // Как в Mos (ScrollCore.swift): перехват на этапе «аннотированного» сеанса, в конце цепочки.
        // Здесь WindowServer уже указал в событии процесс-получатель (окно под курсором), поэтому
        // копию можно отправить прямо ему, и приложение само найдёт нужное окно и панель.
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            lastError = "Не удалось перехватить колесо мыши — проверьте доступ «Универсальный доступ»"
            return false
        }
        self.tap = tap
        guard createDisplayLink() else {
            CFMachPortInvalidate(tap)
            self.tap = nil
            lastError = "Не удалось запустить анимацию прокрутки"
            return false
        }

        // Исключения проверяются по активному приложению; запоминаем его заранее,
        // чтобы не обращаться к NSWorkspace из потока перехватчика.
        lock.withLock { frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.lock.withLock { self?.frontmostBundleID = app?.bundleIdentifier }
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.lock.withLock { self?.tapRunLoop = runLoop }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Mac Utilities scroll wheel"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        lastError = nil
        Log.modules.info("Scroll wheel interceptor started")
        return true
    }

    @MainActor
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop = lock.withLock({ tapRunLoop }) { CFRunLoopStop(runLoop) }
        self.tap = nil
        tapThread = nil
        if let displayLink { CVDisplayLinkStop(displayLink) }
        displayLink = nil
        lock.withLock {
            tapRunLoop = nil
            engine.reset()
            gestureActive = false
            template = nil
        }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func createDisplayLink() -> Bool {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return false }
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context -> CVReturn in
            guard let context else { return kCVReturnSuccess }
            Unmanaged<ScrollWheelInterceptor>.fromOpaque(context).takeUnretainedValue().frame()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        displayLink = link
        return true
    }

    // MARK: - Обработка событий (поток перехватчика)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              // Трекпад и Magic Mouse — непрерывная прокрутка, её не трогаем.
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let (settings, frontmost) = lock.withLock { (sharedSettings, frontmostBundleID) }
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return Unmanaged.passUnretained(event)
        }
        _ = frontmost
        // Приложение, которое получит прокрутку (окно под курсором) — для списка «без плавности».
        let annotatedTarget = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let targetBundle = annotatedTarget != 0 ? NSRunningApplication(processIdentifier: annotatedTarget)?.bundleIdentifier : nil
        let smoothingOff = targetBundle.map(settings.excludedBundleIDs.contains) ?? false

        let lineY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let lineX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let pointY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let pointX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let signY: Double = settings.reverseVertical ? -1 : 1
        let signX: Double = settings.reverseHorizontal ? -1 : 1

        let bypass = !settings.smooth || smoothingOff
        if bypass {
            // Только смена направления, без плавности.
            if signY < 0 { Self.negate(event, line: .scrollWheelEventDeltaAxis1, fixed: .scrollWheelEventFixedPtDeltaAxis1, point: .scrollWheelEventPointDeltaAxis1) }
            if signX < 0 { Self.negate(event, line: .scrollWheelEventDeltaAxis2, fixed: .scrollWheelEventFixedPtDeltaAxis2, point: .scrollWheelEventPointDeltaAxis2) }
            return Unmanaged.passUnretained(event)
        }

        // Как в Mos: берём системный сдвиг в точках (в нём уже учтено ускорение колеса),
        // иначе дробный, иначе строки; щелчок не меньше минимального шага.
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let usableY = pointY != 0 ? pointY : (fixedY != 0 ? fixedY : lineY)
        let usableX = pointX != 0 ? pointX : (fixedX != 0 ? fixedX : lineX)
        var probe = MosScrollEngine()
        probe.step = settings.smoothStep
        // ⌥ + колесо — быстрая прокрутка: путь щелчка умножается (как «рывок» в Mos).
        let boost = settings.fastScrollWithOption && flags.contains(.maskAlternate) ? WheelSettings.fastScrollMultiplier : 1
        let dy = probe.normalized(usableY) * signY * boost
        let dx = probe.normalized(usableX) * signX * boost
        guard dx != 0 || dy != 0, let copy = event.copy() else { return Unmanaged.passUnretained(event) }

        let now = CACurrentMediaTime()
        let location = event.location
        // Получатель — владелец окна ПОД КУРСОРОМ. Поле eventTargetUnixProcessID на этом этапе
        // указывает на активное приложение, а колесом часто крутят фоновые окна.
        // Окно ищется только в начале прокрутки (дальше получатель сохраняется).
        let (idle, currentPID, currentWindow, currentBounds) = lock.withLock { (!timerRunning, targetPID, targetWindow, targetBounds) }
        var pid = currentPID, window = currentWindow, bounds = currentBounds
        // Как в Mos: получатель — процесс, указанный WindowServer в аннотированном событии.
        let annotatedPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        // Новая прокрутка: анимации нет, сменился получатель или щелчок за пределами прежнего окна.
        if idle || currentPID == 0 || annotatedPID != currentPID || !currentBounds.contains(location) {
            let hit = Self.window(at: location)
            pid = annotatedPID != 0 ? annotatedPID : (hit?.pid ?? 0)
            window = hit?.id ?? 0
            bounds = hit?.bounds ?? .null
        }
        let needsStart: Bool = lock.withLock {
            // Новое окно под курсором — начинаем новую прокрутку, старый докат отбрасываем.
            if pid != targetPID || window != targetWindow {
                engine.reset()
                gestureActive = false
            }
            targetPID = pid
            targetWindow = window
            targetBounds = bounds
            anchor = location
            // Прямая доставка процессу (как Mos: ScrollDispatchContext.enqueue → postToPid):
            // докат остаётся в исходном окне и панели, даже если курсор ушёл.
            directDelivery = annotatedPID != 0
            lastCheckedCursor = location
            template = copy
            engine.add(y: dy, x: dx)
            let wasIdle = !timerRunning
            timerRunning = true
            if wasIdle { lastFrame = now }
            return wasIdle
        }
        if needsStart, let displayLink, !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }
        return nil // исходный «щелчок» поглощается
    }

    /// Видимое окно в точке (координаты CG, начало сверху слева) и его владелец.
    static func window(at point: CGPoint) -> (id: CGWindowID, pid: pid_t, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            // Список идёт сверху вниз; служебные слои (курсор, экранные эффекты) пропускаем.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer < 1000,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            // Прозрачные окна Mac Utilities (щит снимка и т.п.) прокрутку не получают.
            if pid == ownPID && layer > 0 { continue }
            return (id, pid, bounds)
        }
        return nil
    }

    /// Путь щелчка колеса: «Шаг щелчка» × число строк (системное ускорение колеса уже
    /// увеличивает число строк при быстром вращении) × скорость.
    static func distance(lines: Double, points: Double, settings: WheelSettings) -> Double {
        guard lines != 0 || points != 0 else { return 0 }
        let direction: Double = (lines != 0 ? lines : points) < 0 ? -1 : 1
        let count = min(max(1, abs(lines)), 4)
        return direction * settings.step * count * settings.speed
    }

    /// Переворачивает направление. Сначала читаем все три поля: запись числа строк заставляет
    /// macOS пересчитать остальные, и повторный переворот вернул бы их обратно.
    static func negate(_ event: CGEvent, line: CGEventField, fixed: CGEventField, point: CGEventField) {
        let lines = event.getIntegerValueField(line)
        let fixedValue = event.getDoubleValueField(fixed)
        let points = event.getDoubleValueField(point)
        event.setIntegerValueField(line, value: -lines)
        event.setDoubleValueField(fixed, value: -fixedValue)
        event.setDoubleValueField(point, value: -points)
    }

    // MARK: - Кадры анимации (поток CVDisplayLink)

    private func frame() {
        var posts: [CGEvent] = []
        var finished = false
        let cursor = CGEvent(source: nil)?.location ?? .zero
        // Запасной путь: курсор сдвинулся — не ушёл ли он на другое окно? Тогда докат обрываем,
        // иначе он прокрутил бы соседнее окно (в том числе того же приложения).
        let (direct, target, bounds, checked, anchorPoint) = lock.withLock { (directDelivery, targetWindow, targetBounds, lastCheckedCursor, anchor) }
        if !direct, hypot(cursor.x - anchorPoint.x, cursor.y - anchorPoint.y) > Self.anchorRadius {
            // Курсор ушёл от места прокрутки — докат обрывается (другое окно или другая панель).
            lock.withLock { engine.reset() }
        } else if !direct, target != 0 {
            if !bounds.isNull, !bounds.contains(cursor) {
                // Курсор вышел за границы окна — докат обрывается сразу, даже при резком рывке.
                lock.withLock { engine.reset() }
            } else if hypot(cursor.x - checked.x, cursor.y - checked.y) > 2 {
                // Внутри границ, но поверх могло оказаться другое окно — проверяем, кто под курсором.
                let hit = Self.window(at: cursor)
                lock.withLock {
                    lastCheckedCursor = cursor
                    if hit?.id != target { engine.reset() }
                }
            }
        }
        lock.withLock {
            let trackpad = sharedSettings.simulateTrackpad
            let output = engine.frame()
            // При прямой доставке координаты остаются исходными; иначе — текущее положение курсора.
            let position: CGPoint? = directDelivery ? nil : cursor
            // Как в Mos: кадр отправляется, только если сдвиг больше порога.
            if max(abs(output.y), abs(output.x)) > engine.deadZone,
               let event = makeEvent(dx: output.x, dy: output.y, phase: trackpad ? (gestureActive ? 2 : 1) : 0, at: position) {
                posts.append(event)
                gestureActive = true
            }
            if engine.isFinished || engine.isIdle {
                engine.reset()
                if trackpad && gestureActive, let end = makeEvent(dx: 0, dy: 0, phase: 4, at: position) { posts.append(end) }
                gestureActive = false
                finished = true
                timerRunning = false
                lastCheckedCursor = CGPoint(x: -1, y: -1)
            }
        }
        let (deliverDirectly, pid) = lock.withLock { (directDelivery, targetPID) }
        for event in posts {
            if deliverDirectly { event.postToPid(pid) } else { event.post(tap: .cgSessionEventTap) }
        }
        if finished, let displayLink { CVDisplayLinkStop(displayLink) }
    }

    /// Копия исходного события колеса с новой величиной прокрутки.
    /// `phase`: 0 — без фаз, 1 — начало, 2 — продолжение, 4 — конец жеста (как у трекпада).
    private func makeEvent(dx: Double, dy: Double, phase: Int64, at cursor: CGPoint?) -> CGEvent? {
        guard let event = template?.copy() else { return nil }
        // Отправка в сеанс — текущее положение курсора: событие со старыми координатами
        // перенесло бы курсор. При прямой доставке (cursor == nil) координаты исходные.
        if let cursor { event.location = cursor }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy / 10)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx / 10)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        return event
    }
}
