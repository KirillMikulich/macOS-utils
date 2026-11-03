import Foundation

/// Чистая математика плавной прокрутки (без системных вызовов — покрыта тестами).
///
/// Каждый щелчок колеса добавляет «путь» в пикселях; на каждом кадре выдаётся доля
/// оставшегося пути (экспоненциальное затухание), так что за `duration` проходит ~95%.
/// Дробные пиксели накапливаются, поэтому суммарный путь не теряется.
struct ScrollSmoother {
    var duration: Double

    private(set) var remainingX = 0.0
    private(set) var remainingY = 0.0
    private var carryX = 0.0
    private var carryY = 0.0

    init(duration: Double) {
        self.duration = max(0.03, duration)
    }

    var isIdle: Bool {
        abs(remainingX) < 0.5 && abs(remainingY) < 0.5
    }

    mutating func add(dx: Double, dy: Double) {
        // Смена направления — остаток в старую сторону сбрасывается, иначе прокрутка «дёргается».
        if dx != 0, remainingX != 0, dx.sign != remainingX.sign { remainingX = 0; carryX = 0 }
        if dy != 0, remainingY != 0, dy.sign != remainingY.sign { remainingY = 0; carryY = 0 }
        remainingX += dx
        remainingY += dy
    }

    mutating func stop() {
        remainingX = 0; remainingY = 0; carryX = 0; carryY = 0
    }

    /// Шаг анимации длительностью `dt` секунд. Возвращает целые пиксели для события.
    mutating func step(dt: Double) -> (dx: Int32, dy: Int32) {
        let fraction = 1 - pow(0.05, dt / max(0.03, duration))
        let dx = Self.take(&remainingX, fraction: fraction, carry: &carryX)
        let dy = Self.take(&remainingY, fraction: fraction, carry: &carryY)
        return (dx, dy)
    }

    /// Шаг анимации без округления (поле PointDelta события — дробное).
    mutating func stepPrecise(dt: Double) -> (dx: Double, dy: Double) {
        let fraction = 1 - pow(0.05, dt / max(0.03, duration))
        return (Self.takePrecise(&remainingX, fraction: fraction), Self.takePrecise(&remainingY, fraction: fraction))
    }

    private static func takePrecise(_ remaining: inout Double, fraction: Double) -> Double {
        guard remaining != 0 else { return 0 }
        var move = remaining * fraction
        // Хвост дотягиваем не медленнее 0,5 pt за кадр.
        if abs(move) < 0.5 { move = remaining < 0 ? max(remaining, -0.5) : min(remaining, 0.5) }
        remaining -= move
        return move
    }

    private static func take(_ remaining: inout Double, fraction: Double, carry: inout Double) -> Int32 {
        guard remaining != 0 else { return 0 }
        // Хвост дотягиваем не медленнее 2 pt за кадр, иначе прокрутка «доползает» долго.
        var move = remaining * fraction
        if abs(move) < 2 { move = remaining < 0 ? max(remaining, -2) : min(remaining, 2) }
        remaining -= move
        carry += move
        let whole = carry.rounded(.towardZero)
        carry -= whole
        return Int32(whole)
    }
}

/// Ускорение при быстрой прокрутке: чем чаще щелчки колеса, тем длиннее шаг.
struct ScrollAcceleration {
    private var lastTick: TimeInterval?
    private(set) var multiplier = 1.0

    /// `now` — время щелчка, `strength` — 0 (нет ускорения) … 1 (сильное).
    mutating func register(at now: TimeInterval, strength: Double) -> Double {
        defer { lastTick = now }
        guard let lastTick, now - lastTick < 0.12, strength > 0 else {
            multiplier = 1
            return multiplier
        }
        multiplier = min(1 + 3 * strength, multiplier + 0.35 * strength)
        return multiplier
    }
}

// MARK: - Ядро плавной прокрутки Mos

/// Перенос ядра плавной прокрутки из Mos — https://github.com/Caldis/Mos (© Caldis,
/// лицензия CC BY-NC 4.0, https://creativecommons.org/licenses/by-nc/4.0/).
/// Источник: Mos/ScrollCore/ScrollPoster.swift (update/processing), Interpolator.lerp,
/// ScrollFilter.polish, ScrollEvent.normalize; значения по умолчанию — Mos/Utils/Constants.swift.
/// Изменения: собрано в одну структуру без глобального состояния, переименованы поля,
/// убраны фазы трекпада и «рывок» (dash), добавлены комментарии на русском.
struct MosScrollEngine {
    /// Минимальный шаг одного щелчка (Mos: step = 33.6).
    var step = 33.6
    /// Множитель пути (Mos: speed = 2.70).
    var speed = 2.70
    /// Доля оставшегося пути за кадр (Mos: duration 4.35 → 1 − √(4.35 / 5.2) ≈ 0.085).
    var transition = MosScrollEngine.transition(forDuration: 4.35)
    /// Порог остановки (Mos: deadZone = 1.0).
    var deadZone = 1.0

    private var bufferY = 0.0, bufferX = 0.0
    private var currentY = 0.0, currentX = 0.0
    private var lastInputY = 0.0, lastInputX = 0.0
    private var filter = CurveFilter()
    private(set) var lastOutput = (y: 0.0, x: 0.0)

    /// Mos: OPTIONS_SCROLL_DEFAULT.generateDurationTransition.
    static func transition(forDuration duration: Double) -> Double {
        let upperLimit = 5.0 + 0.2
        let value = 1 - (duration / upperLimit).squareRoot()
        return (1000 * value).rounded() / 1000
    }

    /// Mos: ScrollEvent.normalize — щелчок не меньше `step`.
    func normalized(_ value: Double) -> Double {
        guard value != 0 else { return 0 }
        return value > 0 ? max(value.magnitude, step) : -max(value.magnitude, step)
    }

    /// Mos: ScrollPoster.update — новый щелчок колеса. В ту же сторону — путь добавляется,
    /// в обратную — начинается заново.
    mutating func add(y: Double, x: Double) {
        if y * lastInputY > 0 {
            bufferY += y * speed
        } else {
            bufferY = y * speed
            currentY = 0
        }
        if x * lastInputX > 0 {
            bufferX += x * speed
        } else {
            bufferX = x * speed
            currentX = 0
        }
        lastInputY = y
        lastInputX = x
    }

    /// Mos: ScrollPoster.processing — следующий кадр: линейная интерполяция к цели
    /// и сглаживание фильтром. Возвращает сдвиг кадра в точках.
    mutating func frame() -> (y: Double, x: Double) {
        let stepY = (bufferY - currentY) * transition
        let stepX = (bufferX - currentX) * transition
        currentY += stepY
        currentX += stepX
        lastOutput = filter.fill(y: stepY, x: stepX)
        return lastOutput
    }

    /// Прокрутка закончилась: до цели и в выдаче меньше порога.
    var isFinished: Bool {
        max(abs(bufferY - currentY), abs(bufferX - currentX)) <= deadZone
            && max(abs(lastOutput.y), abs(lastOutput.x)) <= deadZone
    }

    var isIdle: Bool { bufferY == 0 && bufferX == 0 }

    mutating func reset() {
        bufferY = 0; bufferX = 0; currentY = 0; currentX = 0
        lastInputY = 0; lastInputX = 0; lastOutput = (0, 0)
        filter = CurveFilter()
    }

    /// Mos: ScrollFilter — сглаживание ряда значений кадров: между прошлым и новым значением
    /// строится нелинейный ряд [0, 0.23, 0.5, 0.77, 1], выдаётся его начало.
    struct CurveFilter {
        private var windowY = [0.0, 0.0]
        private var windowX = [0.0, 0.0]

        mutating func fill(y: Double, x: Double) -> (y: Double, x: Double) {
            windowY = Self.polish(windowY, with: y)
            windowX = Self.polish(windowX, with: x)
            return (windowY[0], windowX[0])
        }

        private static func polish(_ array: [Double], with next: Double) -> [Double] {
            let first = array[1]
            let diff = next - first
            return [first, first + 0.23 * diff, first + 0.5 * diff, first + 0.77 * diff, next]
        }
    }
}
