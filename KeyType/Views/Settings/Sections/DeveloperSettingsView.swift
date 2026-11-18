//
//  DeveloperSettingsView.swift
//  KeyType
//
//  The "开发者" Settings pane: diagnostics and local-only tuning controls that aren't part of
//  the everyday flow. Gated features stay opt-in because prompt logs, screenshots, and screen-derived
//  override calibration can contain sensitive local context.
//

import AppCompatibility
import Foundation
import SwiftUI

struct DeveloperSettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var contextCapture: ContextCaptureController
    @Bindable var developerOverrides: DeveloperOverrideController
    let permissions: PermissionsManager
    let openTuningPanel: () -> Void
    let showPlacementProbe: () -> Bool

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $contextCapture.debugOverlayEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示光标调试浮层")
                        Text("标出捕获到的光标、输入框和文字范围，便于检查上下文捕获。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!permissions.accessibility.isGranted)

                Toggle(isOn: $settings.fullPromptLoggingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记录完整提示词和补全")
                        Text("将日志写入 ~/Library/Application Support/KeyType Dev/Logs/\(FullPromptLog.fileName)，保留最近 \(FullPromptLog.maxRows) 行。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("诊断")
            } footer: {
                if !permissions.accessibility.isGranted {
                    Text("需要辅助功能权限。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: developerOverrideEnabledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用实时兼容性调试")
                        Text("从 DeveloperOverrides.json 加载各应用的兼容性设置，并在文件改动时自动更新。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("打开调试浮窗") {
                        openTuningPanel()
                    }
                    .disabled(!settings.developerOverrideTuningEnabled)

                    Button("显示探测框") {
                        _ = showPlacementProbe()
                    }
                    .disabled(!settings.developerOverrideTuningEnabled || contextCapture.latestTunableSnapshot == nil)

                    Button("打开 JSON") {
                        developerOverrides.openOverridesFile()
                    }
                    .disabled(!settings.developerOverrideTuningEnabled)

                    Button("重新加载") {
                        developerOverrides.reloadFromDisk()
                    }
                    .disabled(!settings.developerOverrideTuningEnabled)
                }

                LabeledContent("最近捕获目标") {
                    Text(contextCapture.lastTunableSummary.isEmpty ? "尚未捕获" : contextCapture.lastTunableSummary)
                        .font(.footnote.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                LabeledContent("文件") {
                    Text(developerOverrides.overridesURL.path)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                LabeledContent("已加载") {
                    Text("\(developerOverrides.document.overrides.count) 项兼容性设置")
                }
                if let lastLoadedAt = developerOverrides.lastLoadedAt {
                    LabeledContent("更新时间") {
                        Text(lastLoadedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
                if let lastError = developerOverrides.lastError {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("各应用兼容性设置")
            }
        }
        .formStyle(.grouped)
    }

    private var developerOverrideEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.developerOverrideTuningEnabled },
            set: { isEnabled in
                settings.developerOverrideTuningEnabled = isEnabled
                developerOverrides.setEnabled(isEnabled)
            }
        )
    }
}
