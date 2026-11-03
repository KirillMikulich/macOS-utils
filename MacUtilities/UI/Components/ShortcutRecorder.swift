import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Поле записи горячей клавиши. На время записи глобальные сочетания приложения
/// отключаются, чтобы можно было переназначить в том числе уже занятое сочетание.
struct ShortcutRecorder: View {
    let id: ShortcutID
    @Binding var combo: KeyCombo?
    var defaultCombo: KeyCombo?
    let manager: ShortcutManager

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Text(isRecording ? L("Нажмите сочетание…") : (combo?.displayString ?? L("Не назначено")))
                        .frame(minWidth: 110)
                        .monospaced(!isRecording && combo != nil)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                .help(L("Нажмите, затем введите новое сочетание. Esc — отмена, ⌫ — очистить."))

                if combo != nil && !isRecording {
                    Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(L("Убрать сочетание"))
                }
                if let defaultCombo, defaultCombo != combo, !isRecording {
                    Button { combo = defaultCombo } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help(L("Вернуть по умолчанию (\(defaultCombo.displayString))"))
                }
            }
            let status = manager.status(for: id)
            if status.isProblem {
                Label(status.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        manager.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
                stopRecording()
                return nil
            }
            if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && flags.isEmpty {
                combo = nil
                stopRecording()
                return nil
            }
            guard let newCombo = KeyCombo(event: event), newCombo.isValidGlobalShortcut else {
                NSSound.beep()
                return nil
            }
            combo = newCombo
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            manager.isSuspended = false
        }
    }
}
