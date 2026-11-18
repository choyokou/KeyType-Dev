//
//  ModelSettingsView.swift
//  KeyType
//
//  The "模型" Settings pane: the active model picker, the catalog of downloadable/installed models
//  with their live setup state, and "import your own GGUF". Split out of SettingsView so each sidebar
//  category lives in its own file. See ADR-021.
//

import AppKit
import ModelManagement
import ModelRuntime
import Prompting
import SwiftUI

struct ModelSettingsView: View {
    @Bindable var settings: SettingsStore
    let modelSetup: ModelSetupCoordinator
    let loadState: CompletionController.LoadState
    /// Tear down and reload the completion engine from the currently selected model so a new pick
    /// takes effect immediately (see ADR-021).
    let reloadModel: () -> Void
    /// Present the GGUF import open panel. Owned by `AppDelegate` because it must quiesce the AX
    /// pipeline around the panel to avoid a main-thread deadlock.
    let importModel: () -> Void

    @State private var availableModels: [String] = []
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var savedKeyEndpoint: URL?
    @State private var isReplacingKey = false
    @State private var revealedKey: String?
    @State private var keyError: String?
    @State private var isTesting = false
    @State private var testStatus: String?
    @State private var applyError: String?

    var body: some View {
        Form {
            remoteSettings
            Section("本地模型") {
                if availableModels.isEmpty {
                    LabeledContent("补全模型", value: "未安装本地模型")
                } else {
                    Picker("补全模型", selection: installedModelBinding) {
                        if availableModels.contains(ModelContainer.defaultModelFilename) {
                            Text("默认（\(ModelContainer.defaultModelFilename)）").tag(String?.none)
                        } else {
                            Text("请选择本地模型").tag(String?.none).disabled(true)
                        }
                        ForEach(availableModels, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
            }
            .onChange(of: settings.selectedModelFilename) {
                if settings.remoteCompletion == nil { reloadModel() }
            }

            Section("可用模型") {
                ForEach(modelSetup.catalog) { model in
                    SettingsModelRow(
                        model: model,
                        state: modelSetup.state(for: model),
                        isInstalled: modelSetup.downloads.isInstalled(filename: model.filename),
                        onSetup: { modelSetup.beginSetup(for: model) },
                        onCancel: { modelSetup.cancel(model) },
                        onPause: { modelSetup.pause(model) },
                        onResume: { modelSetup.resume(model) },
                        onDelete: {
                            modelSetup.downloads.deleteModel(filename: model.filename)
                            modelSetup.refresh()
                            availableModels = Self.loadModels()
                        }
                    )
                }
            }

            Section {
                Button("导入 GGUF…", action: importModel)
                    .disabled(isImporting)
                importStatusLine
            } header: {
                Text("导入自己的基础模型")
            } footer: {
                Text("KeyType Dev 针对上面列出的模型进行了适配。其他模型的补全效果可能有差异。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            availableModels = Self.loadModels()
            if let config = settings.remoteCompletion {
                updateBaseURL(config.baseURL)
                modelID = config.model
            }
        }
        .onDisappear { revealedKey = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            revealedKey = nil
        }
        // A download/profile finishing changes a model's setup state but not `availableModels`,
        // which is loaded from disk. Reading every model's state here establishes the observation
        // dependency, so this fires (and re-reads the installed GGUFs) the moment one lands —
        // making freshly downloaded models selectable without a restart.
        .onChange(of: modelSetupSignature) { availableModels = Self.loadModels() }
        // An import lands a brand-new file in the Models directory that isn't in the catalog, so it
        // won't move `modelSetupSignature`. Re-read the installed GGUFs when the import state settles
        // so the freshly imported model appears in (and can be shown selected by) the picker.
        .onChange(of: modelSetup.importState) { availableModels = Self.loadModels() }
    }

    private var remoteSettings: some View {
        Section {
            LabeledContent(loadState == .ready ? "当前使用" : "已应用后端", value: backendLabel)
            switch loadState {
            case .idle, .loading:
                Text("正在准备补全后端…").font(.footnote).foregroundStyle(.secondary)
            case let .unavailable(reason):
                Text("补全暂不可用。\(reason)").font(.footnote).foregroundStyle(.orange)
            case .ready:
                EmptyView()
            }
            HStack {
                Button("OpenAI") { usePreset("https://api.openai.com/v1", model: "") }
                Button("DeepSeek") { usePreset("https://api.deepseek.com", model: "deepseek-flash") }
            }
            .disabled(isTesting)
            TextField(
                "API 基础地址",
                text: Binding(get: { baseURL }, set: updateBaseURL),
                prompt: Text("https://api.example.com/v1")
            )
            .disabled(isTesting)
            apiKeyRows
                .disabled(isTesting)
            TextField("模型 ID", text: $modelID, prompt: Text("填写服务商提供的完整模型 ID"))
                .disabled(isTesting)
            if hasUnappliedDraft {
                Text("API 配置尚未应用。").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("UnappliedAPISettings")
            }
            HStack {
                Button("测试连接") { testConnection() }
                Button("应用 API 配置") { applyRemoteSettings() }
                    .disabled(!hasUnappliedDraft && (settings.remoteCompletion == nil || loadState == .ready))
                if settings.remoteCompletion != nil {
                    Button("使用本地 GGUF", action: switchToLocalModel)
                        .disabled(selectedInstalledModel == nil)
                }
                if isTesting { ProgressView().controlSize(.small) }
            }
            .disabled(isTesting)
            if let testStatus {
                Text(testStatus)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("APIConnectionStatus")
            }
            if let applyError {
                Text(applyError).foregroundStyle(.orange)
            }
            Toggle(isOn: $settings.documentMemoryEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("文档记忆")
                    Text("仅适用于官方 DeepSeek API 和可识别的已保存文档。片段在本机按文档加密保存，每次补全最多发送当前文档的 3 条相关片段。关闭后停止记录和发送。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
                .disabled(settings.remoteCompletion?.supportsDocumentMemory != true)
                .accessibilityLabel("文档记忆")
                .accessibilityHint("每次最多发送当前文档的 3 条相关片段。")
                .accessibilityIdentifier("DocumentMemoryEnabled")
            if settings.remoteCompletion?.supportsDocumentMemory != true {
                Text("应用官方 DeepSeek API 配置后即可开启。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("OpenAI 兼容 API")
        } footer: {
            Text("「测试连接」使用输入框中的配置发送固定示例。「应用 API 配置」将它用于补全。")
                .multilineTextAlignment(.leading)
        }
        .onChange(of: baseURL) { clearDraftFeedback() }
        .onChange(of: modelID) { clearDraftFeedback() }
        .onChange(of: apiKey) { clearDraftFeedback() }
    }

    @ViewBuilder
    private var apiKeyRows: some View {
        if hasSavedKey {
            LabeledContent("API 密钥") {
                HStack {
                    Text("••••••••").accessibilityHidden(true)
                    Text("已保存至钥匙串")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SavedAPIKeyStatus")
                    Button(revealedKey == nil ? "显示" : "隐藏", action: toggleSavedKeyVisibility)
                        .disabled(isReplacingKey)
                    if !isReplacingKey {
                        Button("更换") {
                            revealedKey = nil
                            keyError = nil
                            isReplacingKey = true
                        }
                    }
                }
            }
        }
        if hasSavedKey, let revealedKey {
            Text(verbatim: revealedKey)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .privacySensitive()
                .accessibilityIdentifier("SavedAPIKeyValue")
        }
        if !hasSavedKey || isReplacingKey {
            SecureField(isReplacingKey ? "新 API 密钥" : "API 密钥", text: $apiKey, prompt: Text("输入 API 密钥"))
                .accessibilityIdentifier("APIKeyInput")
        }
        if hasSavedKey, isReplacingKey {
            Button("取消更换") { clearKeyEditor() }
        }
        if let keyError {
            Text(keyError).font(.footnote).foregroundStyle(.orange)
        }
    }

    private var backendLabel: String {
        guard let config = settings.remoteCompletion else { return "本地 GGUF" }
        switch config.endpoint.host {
        case "api.deepseek.com": return "DeepSeek · \(config.model)"
        case "api.openai.com": return "OpenAI · \(config.model)"
        default: return "API · \(config.model)"
        }
    }

    private var installedModelBinding: Binding<String?> {
        Binding(
            get: { settings.selectedModelFilename.flatMap { availableModels.contains($0) ? $0 : nil } },
            set: { settings.selectedModelFilename = $0 }
        )
    }

    private var selectedInstalledModel: String? {
        if let name = installedModelBinding.wrappedValue { return name }
        let defaultName = ModelContainer.defaultModelFilename
        return availableModels.contains(defaultName) ? defaultName : nil
    }

    private func switchToLocalModel() {
        guard let name = selectedInstalledModel,
              let url = try? ModelContainer.modelURL(filename: name),
              ModelContainer.modelExists(at: url) else {
            availableModels = Self.loadModels()
            return
        }
        settings.selectedModelFilename = installedModelBinding.wrappedValue
        settings.remoteCompletion = nil
        reloadModel()
        clearDraftFeedback()
    }

    private var hasUnappliedDraft: Bool {
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let draft = try? RemoteCompletionConfiguration(baseURL: baseURL, model: modelID) {
            return draft != settings.remoteCompletion
        }
        return settings.remoteCompletion != nil ||
            !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clearDraftFeedback() {
        testStatus = nil
        applyError = nil
    }

    private func usePreset(_ url: String, model: String) {
        updateBaseURL(url)
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            modelID = model
        }
        clearDraftFeedback()
    }

    private var draftEndpoint: URL? {
        try? RemoteCompletionConfiguration.endpoint(forBaseURL: baseURL)
    }

    private var hasSavedKey: Bool {
        guard let savedKeyEndpoint else { return false }
        return savedKeyEndpoint == draftEndpoint
    }

    private func updateBaseURL(_ value: String) {
        let previousEndpoint = draftEndpoint
        baseURL = value
        let endpoint = draftEndpoint
        guard endpoint != previousEndpoint else { return }
        clearKeyEditor()
        savedKeyEndpoint = nil
        guard let endpoint else { return }
        do {
            if try RemoteAPIKey.exists(for: endpoint) { savedKeyEndpoint = endpoint }
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func clearKeyEditor() {
        apiKey = ""
        isReplacingKey = false
        revealedKey = nil
        keyError = nil
    }

    private func toggleSavedKeyVisibility() {
        if revealedKey != nil {
            revealedKey = nil
            return
        }
        guard hasSavedKey, let savedKeyEndpoint else { return }
        do {
            revealedKey = try RemoteAPIKey.load(forEndpoint: savedKeyEndpoint)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func remoteDraft() throws -> (RemoteCompletionConfiguration, String, Bool) {
        let config = try RemoteCompletionConfiguration(baseURL: baseURL, model: modelID)
        let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNewKey = !enteredKey.isEmpty
        let key = try hasNewKey ? enteredKey : RemoteAPIKey.load(for: config)
        return (config, key, hasNewKey)
    }

    private func testConnection() {
        do {
            let (config, key, _) = try remoteDraft()
            let generator = RemoteCompletionGenerator(configuration: config, apiKey: key)
            isTesting = true
            clearDraftFeedback()
            Task {
                defer { isTesting = false }
                do {
                    try await generator.testConnection()
                    testStatus = "测试成功。此配置已收到模型响应。"
                } catch {
                    testStatus = "测试失败。\(error.localizedDescription)"
                }
            }
        } catch {
            testStatus = "测试失败。\(error.localizedDescription)"
        }
    }

    private func applyRemoteSettings() {
        do {
            let (config, key, hasNewKey) = try remoteDraft()
            if hasNewKey { try RemoteAPIKey.save(key, for: config) }
            settings.remoteCompletion = config
            savedKeyEndpoint = config.endpoint
            clearKeyEditor()
            reloadModel()
            applyError = nil
        } catch {
            applyError = "无法应用配置。\(error.localizedDescription)"
        }
    }

    /// Changes whenever any catalog model's combined setup state changes, so the picker stays in sync.
    private var modelSetupSignature: String {
        modelSetup.catalog
            .map { "\($0.filename):\(String(describing: modelSetup.state(for: $0)))" }
            .joined(separator: "|")
    }

    private var isImporting: Bool {
        if case .preparing = modelSetup.importState { return true }
        return false
    }

    @ViewBuilder
    private var importStatusLine: some View {
        switch modelSetup.importState {
        case .idle:
            EmptyView()
        case .preparing(let filename):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在准备 \(filename)…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private static func loadModels() -> [String] {
        guard let dir = try? ModelContainer.modelsDirectoryURL(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension.lowercased() == "gguf" && ModelContainer.modelExists(at: $0) }
            .map(\.lastPathComponent)
            .sorted()
    }
}

/// One catalog model row in Settings: name, size, live setup state, and the contextual action
/// (Set up / Cancel / Delete).
private struct SettingsModelRow: View {
    let model: DownloadableRuntimeModel
    let state: ModelSetupCoordinator.SetupState
    let isInstalled: Bool
    let onSetup: () -> Void
    let onCancel: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                    Text(model.approximateSizeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                action
            }
            statusLine
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .ready:
            Button("删除", role: .destructive, action: onDelete)
                .font(.callout)
        case .downloading:
            HStack(spacing: 8) {
                Button("暂停", action: onPause)
                Button("取消", action: onCancel)
            }
            .font(.callout)
        case .paused:
            HStack(spacing: 8) {
                Button("继续下载", action: onResume)
                Button("取消", action: onCancel)
            }
            .font(.callout)
        case .preparingProfile:
            Button("取消", action: onCancel)
                .font(.callout)
        case .idle, .failed:
            if isInstalled {
                HStack(spacing: 8) {
                    Button("准备模型", action: onSetup)
                    Button("删除", role: .destructive, action: onDelete)
                }
                .font(.callout)
            } else {
                Button("设置", action: onSetup)
                    .font(.callout)
                    .disabled(!model.isDownloadable)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .idle:
            if let reason = model.unavailableReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress)
                Text("正在下载 \(Int((progress * 100).rounded()))%")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .paused(let progress):
            ProgressView(value: progress ?? 0)
            Text(progress != nil ? "已暂停（\(Int((progress! * 100).rounded()))%）" : "已暂停")
                .font(.footnote).foregroundStyle(.secondary)
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
