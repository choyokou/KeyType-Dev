//
//  GeneralSettingsView.swift
//  KeyType
//
//  The "通用" Settings pane: completion length. Split out of SettingsView so each sidebar
//  category lives in its own file.
//

import LaunchAtLogin
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("启动") {
                LaunchAtLogin.Toggle("登录时启动")
                Text("登录 Mac 后自动启动 KeyType Dev。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("补全长度") {
                Picker("长度", selection: $settings.completionLength) {
                    ForEach(CompletionLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                .pickerStyle(.segmented)
                Text("补全越短，建议越简洁。补全越长，一次建议的内容越多。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("自动纠错") {
                Toggle("启用纠错建议", isOn: $settings.autocorrectSuggestionsEnabled)
                Toggle("显示建议的改法", isOn: $settings.showSuggestedFixes)
            }
        }
        .formStyle(.grouped)
    }
}
