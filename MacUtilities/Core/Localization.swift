import Foundation
import Observation

/// Язык интерфейса. Исходные строки в коде — русские; английский перевод лежит в `en.json`.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    /// Название языка на нём самом — понятно при любом текущем языке.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

/// Текущий язык. Наблюдаемый: SwiftUI-представления, вызвавшие `L(...)`, перерисовываются
/// при смене языка сами, без перезапуска приложения.
@Observable
final class Localization: @unchecked Sendable {
    static let shared = Localization()

    var language: AppLanguage = .english

    /// Русский ключ → английский перевод.
    @ObservationIgnored private let english: [String: String]

    private init() {
        if let url = Bundle.main.url(forResource: "en", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let table = try? JSONDecoder().decode([String: String].self, from: data) {
            english = table
        } else {
            english = [:]
        }
    }

    func template(for key: String) -> String {
        switch language {
        case .russian: return key
        case .english: return english[key] ?? key
        }
    }

    /// Есть ли перевод для ключа (для тестов полноты перевода).
    func hasEnglish(_ key: String) -> Bool { english[key] != nil }
}

/// Ключ перевода: русская строка, в которой каждая интерполяция заменена на `%@`.
/// Значения интерполяций подставляются в перевод по порядку (или по `%1$@`, `%2$@`).
struct LocalizedKey: ExpressibleByStringInterpolation {
    var key: String
    var arguments: [String] = []

    init(stringLiteral value: String) {
        key = value
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ literal: String) {
            // Знак % в тексте не путается с подстановками: подставляются только %@ и %N$@.
            key += literal
        }

        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value))
        }

        /// Как `Text("\(value, specifier: "%.2f")")`.
        mutating func appendInterpolation<T: CVarArg>(_ value: T, specifier: String) {
            key += "%@"
            arguments.append(String(format: specifier, locale: Localization.shared.language.locale, value))
        }
    }
}

/// Перевод строки интерфейса на текущий язык.
func L(_ key: LocalizedKey) -> String {
    let template = Localization.shared.template(for: key.key)
    guard !key.arguments.isEmpty else { return template }
    var result = template
    // Позиционные подстановки (%1$@) — для переводов, где порядок слов другой.
    for (index, argument) in key.arguments.enumerated() {
        result = result.replacingOccurrences(of: "%\(index + 1)$@", with: argument)
    }
    var output = ""
    var rest = Substring(result)
    var next = key.arguments.makeIterator()
    while let range = rest.range(of: "%@") {
        output += rest[..<range.lowerBound]
        output += next.next() ?? ""
        rest = rest[range.upperBound...]
    }
    return output + rest
}
