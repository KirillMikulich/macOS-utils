import SwiftUI

/// Предупреждение о недостающем разрешении с кнопками «Открыть настройки» и «Проверить снова».
struct PermissionBanner: View {
    let kind: PermissionKind
    let permissions: PermissionManager
    var isRequired = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isRequired ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isRequired ? .orange : .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(isRequired ? "Требуется: \(kind.title)" : "Рекомендуется: \(kind.title)")
                    .font(.callout.weight(.semibold))
                Text(kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Открыть настройки") { permissions.request(kind) }
                    Button("Проверить снова") { permissions.refresh() }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background((isRequired ? Color.orange : Color.blue).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Строка «название — элемент управления» для форм настроек.
struct SettingsCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
