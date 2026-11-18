//
//  InputMethodsSettingsView.swift
//  KeyType
//
//  Per-input-method KeyType enablement. The list mirrors the selectable keyboard input sources
//  currently enabled in macOS; methods absent from the saved deny-list are on by default.
//

import SwiftUI

struct InputMethodsSettingsView: View {
    @Bindable var inputMethods: InputMethodController

    var body: some View {
        Form {
            Section("可用输入法") {
                Text("选择哪些 macOS 输入法可以使用补全。新添加的输入法默认开启补全。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if inputMethods.activeInputMethods.isEmpty {
                    Text("未检测到可用输入法。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(inputMethods.activeInputMethods) { inputMethod in
                    Toggle(isOn: Binding(
                        get: { inputMethods.isEnabled(inputMethod) },
                        set: { inputMethods.setEnabled($0, for: inputMethod) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(inputMethod.name)
                                if inputMethod.identifier == inputMethods.selectedInputMethodIdentifier {
                                    Text("当前")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            Text(inputMethod.identifier)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Button("刷新输入法列表") {
                    inputMethods.refresh()
                }
                .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .onAppear { inputMethods.refresh() }
    }
}
