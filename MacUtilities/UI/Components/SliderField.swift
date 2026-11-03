import SwiftUI

/// Строка настроек: ползунок + поле точного ввода. Введённое число ограничивается диапазоном.
/// `scale` — множитель для отображения (например, 100 для процентов при значении 0…1).
struct SliderField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var unit: String = ""
    var fractionDigits = 0
    var scale = 1.0

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                NumberField(value: $value, range: range, fractionDigits: fractionDigits, scale: scale)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .leading)
                }
            }
            .frame(maxWidth: 300)
        }
    }
}

/// Поле для точного числа: применяется по Return или при уходе фокуса, значение — в пределах диапазона.
struct NumberField<Value: BinaryFloatingPoint>: View {
    @Binding var value: Value
    let range: ClosedRange<Value>
    var fractionDigits = 0
    var scale = 1.0
    var width: CGFloat = 56

    var body: some View {
        TextField("", value: Binding(
            get: { Double(value) * scale },
            set: { value = min(max(Value($0 / scale), range.lowerBound), range.upperBound) }
        ), format: .number.precision(.fractionLength(fractionDigits)).grouping(.never))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: width)
        .labelsHidden()
    }
}
