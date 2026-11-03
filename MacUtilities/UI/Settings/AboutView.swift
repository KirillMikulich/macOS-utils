import SwiftUI

struct AboutView: View {
    let coordinator: AppCoordinator

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mac Utilities").font(.title.weight(.semibold))
                        Text(L("Версия \(version)")).foregroundStyle(.secondary)
                        Text(L("Набор системных утилит для macOS: история буфера обмена, переключатель окон и предпросмотр окон из Dock."))
                            .font(.callout)
                    }
                }
                .padding(.vertical, 6)
            }
            Section(L("Приватность")) {
                Text(L("Приложение работает полностью локально: нет сетевых запросов, аналитики и облачной синхронизации. Содержимое буфера и изображения окон не покидают этот Mac."))
            }
            Section(L("Использованный код")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Плавная прокрутка колесом мыши — Mos, автор Caldis"))
                    Link("https://github.com/Caldis/Mos", destination: URL(string: "https://github.com/Caldis/Mos")!)
                    Text(L("Лицензия CC BY-NC 4.0 (некоммерческое использование с указанием автора). Перенесены интерполяция, сглаживающий фильтр, значения по умолчанию и доставка событий; изменения — объединение в один модуль и русские комментарии."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Системные возможности")) {
                LabeledContent(L("Поиск CGWindowID окна"),
                               value: AX.hasPrivateWindowIDLookup ? L("_AXUIElementGetWindow (недокументированный API)") : L("Сопоставление по рамке окна"))
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
        }
        .formStyle(.grouped)
    }
}
