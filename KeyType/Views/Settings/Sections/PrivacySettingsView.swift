//
//  PrivacySettingsView.swift
//  KeyType
//
//  The "隐私" Settings pane: the switches that gate sensitive context (history, clipboard, OCR)
//  and the single "Clear all personal data" action. Split out of SettingsView so each sidebar
//  category lives in its own file. See ADR-023.
//

import SwiftUI
import Prompting

struct PrivacySettingsView: View {
    @Bindable var settings: SettingsStore
    let permissions: PermissionsManager
    let clearPersonalData: () -> Void

    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section("API 补全发送的内容") {
                Text("API 补全会把当前输入框光标前最多 \(RemoteCompletionGenerator.cursorContextLimit) 个字符发给所选服务商。")
                Text("开启文档记忆后，DeepSeek 每次还可收到当前文档的最多 3 条相关片段。")
                Text("写作历史、剪贴板和屏幕识别结果仅用作本地模型的上下文。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("隐私") {
                Toggle(isOn: $settings.historyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("根据写作历史改进建议")
                        Text("在本机加密保存近期输入，用于改进补全。默认开启。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.clipboardEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("将剪贴板用作上下文")
                        Text("将剪贴板中的文字加入模型提示词。默认开启。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.ocrEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("使用屏幕文字作为上下文（OCR，测试版）")
                        Text("识别当前窗口的可见文字。默认关闭，需要屏幕录制权限。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if settings.ocrEnabled, !permissions.screenRecording.isGranted {
                            Text("请在「系统设置」中授予屏幕录制权限，才能启用 OCR 上下文。")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .onChange(of: settings.ocrEnabled) { _, isOn in
                    // Enabling OCR is useless without Screen Recording; pop the system prompt and
                    // deep-link to the pane so the toggle is actionable rather than silently inert.
                    if isOn, !permissions.screenRecording.isGranted {
                        _ = permissions.requestScreenRecording()
                        permissions.openScreenRecordingSettings()
                    }
                }
                Toggle(isOn: $settings.screenshotCalibrationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("使用屏幕截图校准灰字显示")
                        Text("根据当前输入框校准灰字字号和垂直位置。默认关闭，需要屏幕录制权限。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if settings.screenshotCalibrationEnabled, !permissions.screenRecording.isGranted {
                            Text("请在「系统设置」中授予屏幕录制权限，才能启用截图校准。")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .onChange(of: settings.screenshotCalibrationEnabled) { _, isOn in
                    if isOn, !permissions.screenRecording.isGranted {
                        _ = permissions.requestScreenRecording()
                        permissions.openScreenRecordingSettings()
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Text("清除本机个人数据…")
                }
                .confirmationDialog(
                    "清除本机个人数据？",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("全部清除", role: .destructive) {
                        clearPersonalData()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除此 Mac 上的写作历史、文档记忆和本地统计。此操作无法撤销。")
                }
            } footer: {
                Text("KeyType Dev 保存的记录存放在这台 Mac 上。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
