//
//  ShortcutsSettingsView.swift
//  KeyType
//
//  The "快捷键" Settings pane: the keys used to accept a suggestion. Split out of SettingsView so
//  each sidebar category lives in its own file.
//

import SwiftUI

struct ShortcutsSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                KeyRecorderView(
                    title: "分段接受建议",
                    subtitle: "中文尽量按短语接受，其他文字按词接受。",
                    shortcut: settings.acceptWordShortcut,
                    onChange: { settings.acceptWordShortcut = $0 },
                    onClear: { settings.acceptWordShortcut = .unassigned },
                    onReset: settings.acceptWordShortcut != .defaultAcceptWord
                        ? { settings.acceptWordShortcut = .defaultAcceptWord } : nil
                )
                KeyRecorderView(
                    title: "接受整条建议",
                    subtitle: "一次插入整条灰字建议。",
                    shortcut: settings.acceptFullShortcut,
                    onChange: { settings.acceptFullShortcut = $0 },
                    onClear: { settings.acceptFullShortcut = .unassigned },
                    onReset: settings.acceptFullShortcut != .defaultAcceptFull
                        ? { settings.acceptFullShortcut = .defaultAcceptFull } : nil
                )
                KeyRecorderView(
                    title: "接受纠错建议",
                    subtitle: "用显示的纠错建议替换拼错的词。",
                    shortcut: settings.acceptCorrectionShortcut,
                    onChange: { settings.acceptCorrectionShortcut = $0 },
                    onClear: { settings.acceptCorrectionShortcut = .unassigned },
                    onReset: settings.acceptCorrectionShortcut != .defaultAcceptCorrection
                        ? { settings.acceptCorrectionShortcut = .defaultAcceptCorrection } : nil
                )
            } header: {
                Text("接受建议的快捷键")
            } footer: {
                Text("清除快捷键后，该操作不再绑定按键。")
            }
        }
        .formStyle(.grouped)
    }
}
