//
//  OnboardingView.swift
//  KeyType
//
//  First-run onboarding wizard. A finite, guided flow:
//  welcome -> permissions -> model -> privacy -> keybinds -> turn off macOS predictions -> done.
//
//  Layout invariants (mirrored from the reference design): the Back/Continue footer is pinned
//  outside the scrolling content so a tall step can never push Continue off-screen, and each middle
//  step shows a progress indicator so the flow reads as finite.
//

import AppKit
import ModelManagement
import ModelRuntime
import SwiftUI

struct OnboardingView: View {
    let permissionGuidance: PermissionGuidanceController
    var markCompleted: () -> Void = {}

    @Environment(PermissionsManager.self) private var permissions
    @Environment(SettingsStore.self) private var settings
    @Environment(ModelSetupCoordinator.self) private var modelSetup
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var step: Step = .welcome
    @State private var selectedModelFilename: String = ModelContainer.defaultModelFilename

    var body: some View {
        VStack(spacing: 0) {
            if let index = step.progressIndex {
                StepProgress(current: index, total: Step.totalProgressSteps)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 4)
            }

            ScrollView {
                stepContent
                    .padding(.horizontal, 28)
                    .padding(.top, step.progressIndex == nil ? 28 : 14)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 22)
        }
        .frame(width: 480, height: 600)
        .task {
            permissions.refresh()
            modelSetup.refresh()
        }
        // The guided overlay is a floating panel tied to the permissions step. Tear it down when the
        // user navigates away or closes onboarding so it can't linger over System Settings.
        .onChange(of: step) { _, newStep in
            if newStep != .permissions { permissionGuidance.dismiss() }
        }
        .onDisappear { permissionGuidance.dismiss() }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .model: modelStep
        case .privacy: privacyStep
        case .keybinds: keybindsStep
        case .predictions: predictionsStep
        case .done: doneStep
        }
    }

    // MARK: - Footer / navigation

    @ViewBuilder
    private var footer: some View {
        switch step {
        case .welcome:
            HStack {
                Spacer()
                Button("开始使用") { step = .permissions }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .done:
            HStack {
                Spacer()
                Button("打开模型设置") {
                    finish()
                    openWindow(id: AppDelegate.settingsWindowID)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .permissions:
            navigation(
                back: .welcome,
                next: .model,
                canContinue: permissions.requiredPermissionsGranted,
                disabledHint: "授予辅助功能和输入监控权限后继续。"
            )
        case .model:
            navigation(
                back: .permissions,
                next: .privacy,
                canContinue: selectedModelIsReady,
                disabledHint: "请选择一个模型，或点击「稍后设置」。",
                trailingAccessory: selectedModelIsReady ? nil : AnyView(
                    Button("稍后设置") { step = .privacy }
                        .buttonStyle(.link)
                )
            )
        case .privacy:
            navigation(back: .model, next: .keybinds, canContinue: true)
        case .keybinds:
            navigation(back: .privacy, next: .predictions, canContinue: true)
        case .predictions:
            navigation(back: .keybinds, next: .done, canContinue: true)
        }
    }

    private func navigation(
        back: Step,
        next: Step,
        canContinue: Bool,
        disabledHint: String = "",
        trailingAccessory: AnyView? = nil
    ) -> some View {
        HStack {
            Button("返回") { step = back }
                .controlSize(.large)
            Spacer()
            if let trailingAccessory { trailingAccessory }
            Button("继续") { step = next }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)
                .help(canContinue ? "" : disabledHint)
        }
    }

    private func finish() {
        markCompleted()
        dismissWindow(id: AppDelegate.onboardingWindowID)
    }

    private var selectedModelIsReady: Bool {
        guard let model = modelSetup.catalog.first(where: { $0.filename == selectedModelFilename }) else {
            return false
        }
        return modelSetup.isFullyInstalled(model)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.cursor")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text("欢迎使用 KeyType Dev")
                .font(.title.weight(.semibold))
            Text("在 Mac 上输入时显示灰字补全，按 Tab 接受建议。可使用本地模型，也可在设置中接入 API。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    @ViewBuilder
    private var permissionsStep: some View {
        StepHeader(
            title: "启用 KeyType Dev",
            subtitle: "需要授予两项 macOS 权限，才能读取当前输入框并响应补全快捷键。"
        )
        VStack(spacing: 10) {
            PermissionCard(
                kind: .accessibility,
                requirement: .required,
                explanation: "读取当前输入框的内容和光标位置。",
                isGranted: permissions.accessibility.isGranted,
                guidance: permissionGuidance
            )
            PermissionCard(
                kind: .inputMonitoring,
                requirement: .required,
                explanation: "识别你设置的全局快捷键，以便插入补全内容。",
                isGranted: permissions.inputMonitoring.isGranted,
                guidance: permissionGuidance
            )
            PermissionCard(
                kind: .screenRecording,
                requirement: .optional,
                explanation: "在「隐私」中启用后，可识别当前窗口的可见文字（OCR），补充上下文。",
                isGranted: permissions.screenRecording.isGranted,
                guidance: permissionGuidance
            )
        }
    }

    @ViewBuilder
    private var modelStep: some View {
        StepHeader(
            title: "选择模型",
            subtitle: "请选择要下载的本地模型，或使用已添加的模型。要用 API，可先选「稍后设置」。"
        )
        VStack(spacing: 10) {
            ForEach(modelSetup.catalog) { model in
                ModelCard(
                    model: model,
                    state: modelSetup.state(for: model),
                    isSelected: selectedModelFilename == model.filename,
                    onSelect: {
                        selectedModelFilename = model.filename
                        modelSetup.beginSetup(for: model)
                    },
                    onCancel: { modelSetup.cancel(model) },
                    onPause: { modelSetup.pause(model) },
                    onResume: { modelSetup.resume(model) }
                )
            }
        }
    }

    @ViewBuilder
    private var privacyStep: some View {
        @Bindable var settings = settings
        StepHeader(
            title: "隐私",
            subtitle: "写作历史和剪贴板辅助默认开启，可在这里调整。本机记录保存在这台 Mac 上。"
        )
        VStack(spacing: 10) {
            ToggleCard(
                title: "根据写作历史改进建议",
                detail: "在本机加密保存近期输入，用于改进补全。",
                isOn: $settings.historyEnabled
            )
            ToggleCard(
                title: "将剪贴板用作上下文",
                detail: "将剪贴板中的文字加入模型提示词。",
                isOn: $settings.clipboardEnabled
            )
        }
    }

    @ViewBuilder
    private var keybindsStep: some View {
        @Bindable var settings = settings
        StepHeader(
            title: "接受建议的快捷键",
            subtitle: "点击「更改」后按下你想使用的键。点击「清除」可取消绑定。"
        )
        VStack(spacing: 10) {
            CardContainer {
                KeyRecorderView(
                    title: "分段接受建议",
                    subtitle: "中文尽量按短语接受，其他文字按词接受。",
                    shortcut: settings.acceptWordShortcut,
                    onChange: { settings.acceptWordShortcut = $0 },
                    onClear: { settings.acceptWordShortcut = .unassigned },
                    onReset: settings.acceptWordShortcut != .defaultAcceptWord
                        ? { settings.acceptWordShortcut = .defaultAcceptWord } : nil
                )
            }
            CardContainer {
                KeyRecorderView(
                    title: "接受整条建议",
                    subtitle: "一次插入整条灰字建议。",
                    shortcut: settings.acceptFullShortcut,
                    onChange: { settings.acceptFullShortcut = $0 },
                    onClear: { settings.acceptFullShortcut = .unassigned },
                    onReset: settings.acceptFullShortcut != .defaultAcceptFull
                        ? { settings.acceptFullShortcut = .defaultAcceptFull } : nil
                )
            }
        }
    }

    @ViewBuilder
    private var predictionsStep: some View {
        StepHeader(
            title: "关闭 macOS 内联预测",
            subtitle: "关闭 macOS 自带的内联预测，可避免它与 KeyType Dev 同时显示灰字。"
        )
        VStack(alignment: .leading, spacing: 14) {
            CardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text("打开「键盘」设置后，按以下步骤操作。")
                            .font(.callout.weight(.medium))
                    } icon: {
                        Image(systemName: "keyboard")
                    }
                    instructionRow(number: 1, text: "在「文本输入」中，点击「输入法」旁的「编辑…」。")
                    instructionRow(number: 2, text: "关闭「显示内联预测文本」。")
                    instructionRow(number: 3, text: "点击「完成」。")

                    if let enabled = PermissionsManager.inlinePredictionDefaultEnabled() {
                        Label(
                            enabled ? "检测到内联预测仍开启。" : "检测到内联预测已关闭。",
                            systemImage: enabled ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(enabled ? Color.orange : Color.green)
                        .padding(.top, 2)
                    }

                    Button("打开键盘设置") { permissions.openKeyboardSettings() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
            Text("可跳过此步骤。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12))
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 64, height: 64)
            .padding(.top, 12)

            Text("设置完成")
                .font(.title.weight(.semibold))
            Text("在任意支持的输入框中开始打字。\(acceptanceShortcutSummary)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Label("你可以在菜单栏找到 KeyType Dev。", systemImage: "menubar.arrow.up.rectangle")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var acceptanceShortcutSummary: String {
        let word = settings.acceptWordShortcut
        let full = settings.acceptFullShortcut

        switch (word.isAssigned, full.isAssigned) {
        case (true, true):
            return "按 \(word.displayString) 分段接受，按 \(full.displayString) 接受整条建议。"
        case (true, false):
            return "按 \(word.displayString) 分段接受。接受整条建议的快捷键尚未设置。"
        case (false, true):
            return "按 \(full.displayString) 接受整条建议。分段接受的快捷键尚未设置。"
        case (false, false):
            return "尚未设置接受建议的快捷键，可以在「快捷键」设置中添加。"
        }
    }

    // MARK: - Step model

    enum Step: Int, CaseIterable {
        case welcome, permissions, model, privacy, keybinds, predictions, done

        static let totalProgressSteps = 5

        /// 1-based index inside the progress indicator, or `nil` for the intro/outro steps.
        var progressIndex: Int? {
            switch self {
            case .welcome, .done: return nil
            case .permissions: return 1
            case .model: return 2
            case .privacy: return 3
            case .keybinds: return 4
            case .predictions: return 5
            }
        }
    }
}

// MARK: - Reusable pieces

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

private struct StepProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(1...total, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == current ? 22 : 16, height: 5)
                        .animation(.easeInOut(duration: 0.2), value: current)
                }
            }
            Text("第 \(current) 步，共 \(total) 步")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CardContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
    }
}

private struct ToggleCard: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        CardContainer {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PermissionCard: View {
    enum Requirement {
        case required, optional
        var label: String { self == .required ? "必需" : "可选" }
        var tint: Color { self == .required ? .accentColor : .secondary }
    }

    let kind: PermissionKind
    let requirement: Requirement
    let explanation: String
    let isGranted: Bool
    let guidance: PermissionGuidanceController

    /// Screen-space rect of the Allow button, captured so the guided overlay can animate out of it.
    @State private var allowButtonFrame = CGRect.zero

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isGranted ? Color.green : (requirement == .required ? Color.orange : Color.secondary))
                    Text(kind.title).font(.headline)
                    Text(requirement.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(requirement.tint.opacity(0.15)))
                        .foregroundStyle(requirement.tint)
                    Spacer()
                    Text(isGranted ? "已授权" : "未授权")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isGranted ? Color.green : Color.secondary)
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isGranted {
                    Button("授权") {
                        guidance.requestAccess(for: kind, sourceFrameInScreen: allowButtonFrame)
                    }
                    .buttonStyle(.borderedProminent)
                    .background(ScreenFrameReader(frameInScreen: $allowButtonFrame))
                }
            }
        }
    }
}

private struct ModelCard: View {
    let model: DownloadableRuntimeModel
    let state: ModelSetupCoordinator.SetupState
    let isSelected: Bool
    let onSelect: () -> Void
    let onCancel: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).font(.headline)
                        Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(model.approximateSizeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if isSelected, case .ready = state {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                statusView
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .idle:
            EmptyView()
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                HStack(spacing: 12) {
                    Text(progress != nil ? "正在下载 \(Int((progress! * 100).rounded()))%" : "正在下载…")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("暂停", action: onPause).font(.footnote)
                    Button("取消", action: onCancel).font(.footnote)
                }
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress ?? 0)
                HStack(spacing: 12) {
                    Text(progress != nil ? "已暂停（\(Int((progress! * 100).rounded()))%）" : "已暂停")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("继续下载", action: onResume).font(.footnote)
                    Button("取消", action: onCancel).font(.footnote)
                }
            }
        case .preparingProfile:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在准备模型…").font(.footnote).foregroundStyle(.secondary)
            }
        case .ready:
            Label("已就绪", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
