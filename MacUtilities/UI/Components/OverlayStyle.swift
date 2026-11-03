import AppKit
import Observation
import SwiftUI

/// Оформление плавающих панелей: история буфера, переключатель окон, превью в Dock.
struct OverlayStyleSettings: Codable, Equatable {
    enum Theme: String, Codable, CaseIterable, Identifiable {
        case glass, dark, light, solid
        var id: String { rawValue }
        var title: String {
            switch self {
            case .glass: return "Стекло"
            case .dark: return "Тёмная"
            case .light: return "Светлая"
            case .solid: return "Плотная"
            }
        }
    }

    enum Accent: String, Codable, CaseIterable, Identifiable {
        case system, blue, purple, pink, red, orange, green, graphite
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Как в системе"
            case .blue: return "Синий"
            case .purple: return "Фиолетовый"
            case .pink: return "Розовый"
            case .red: return "Красный"
            case .orange: return "Оранжевый"
            case .green: return "Зелёный"
            case .graphite: return "Графит"
            }
        }
        var color: Color {
            switch self {
            case .system: return .accentColor
            case .blue: return .blue
            case .purple: return .purple
            case .pink: return .pink
            case .red: return .red
            case .orange: return .orange
            case .green: return .green
            case .graphite: return .gray
            }
        }
    }

    var theme: Theme = .glass
    var accent: Accent = .system
    var cornerRadius = 16.0
    var shadow = true

    static let cornerRadiusRange = 4.0...28.0
}

/// Текущее оформление панелей (обновляется из общих настроек, панели перерисовываются сами).
@MainActor
@Observable
final class OverlayStyle {
    static let shared = OverlayStyle()
    var settings = OverlayStyleSettings()

    var accent: Color { settings.accent.color }
    var cornerRadius: CGFloat { settings.cornerRadius }

    /// Схема для тёмной и светлой тем; для «стекла» и «плотной» — как в системе.
    var colorScheme: ColorScheme? {
        switch settings.theme {
        case .dark: return .dark
        case .light: return .light
        case .glass, .solid: return nil
        }
    }
}

/// Фон панели по выбранной теме. `opacity` — непрозрачность фона (содержимое не затрагивается).
struct OverlayBackground: View {
    var opacity: Double
    private var style: OverlayStyle { OverlayStyle.shared }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        ZStack {
            switch style.settings.theme {
            case .glass:
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.35))
            case .dark:
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color(white: 0.1).opacity(0.85))
            case .light:
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color(white: 0.98).opacity(0.88))
            case .solid:
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            }
        }
        .opacity(opacity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator.opacity(0.5)))
    }
}

extension View {
    /// Применяет тему панелей: цветовую схему и цвет выделения.
    func overlayStyled() -> some View {
        modifier(OverlayStyledModifier())
    }
}

private struct OverlayStyledModifier: ViewModifier {
    func body(content: Content) -> some View {
        let style = OverlayStyle.shared
        if let scheme = style.colorScheme {
            content.environment(\.colorScheme, scheme).tint(style.accent)
        } else {
            content.tint(style.accent)
        }
    }
}
