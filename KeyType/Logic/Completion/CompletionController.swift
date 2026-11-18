//
//  CompletionController.swift
//  KeyType
//
//  Orchestrates the live completion pipeline (M6): focused-field snapshots → prompt → constrained
//  generation → candidate filtering → inline ghost-text overlay, plus Tab/Shift+Tab acceptance via
//  TextInsertion. Generation runs off the main actor (the runtime is an actor) and is cancelled by
//  the next keystroke. See ADR-016.
//

import AppCompatibility
import AppKit
import ApplicationServices
import AutocompleteCore
import CompletionUI
import ConstrainedGeneration
import CoreGraphics
import Foundation
import LlamaModelRuntime
import MacContextCapture
import ModelManagement
import ModelRuntime
import Observation
import Personalization
import Prompting
import TextInsertion
import TokenProfiles
import os

/// Retains model-using tasks until they have actually returned. Cancellation alone is not a
/// teardown barrier: a task can be suspended in a non-cancellation-aware Metal command-buffer wait
/// and keep using llama.cpp after its caller has moved on. Keeping every superseded task here lets
/// reload/quit cancel *and join* all of them before native model resources are freed.
@MainActor
final class CompletionTaskRegistry {
    struct Handle {
        fileprivate let task: Task<Void, Never>

        func cancel() {
            task.cancel()
        }
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var isClosed = false

    var activeTaskCount: Int {
        tasks.count
    }

    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Handle? {
        guard !isClosed else { return nil }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.tasks.removeValue(forKey: id)
        }
        tasks[id] = task
        return Handle(task: task)
    }

    func cancelAllAndWait() async {
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }
        for task in pending {
            await task.value
        }
    }

    func closeAndWait() async {
        isClosed = true
        await cancelAllAndWait()
    }
}

enum CompletionTextMutation: Equatable {
    case inserted(String)
    case deleteBackward
    case deleteForward
    case nonText
}

private final class CompletionLatencyTrace: @unchecked Sendable {
    private static let signpostLog = OSLog(
        subsystem: "com.pattonium.KeyType",
        category: "completion-latency"
    )

    /// Outcome string passed to `finish(outcome:)` when a completion was actually painted on screen.
    /// Kept in one place so `present(...)` and the telemetry-write decision in `finish` can't drift.
    static let shownOutcome = "shown"

    private let id: OSSignpostID
    private let startedAt: DispatchTime
    private let telemetry: CompletionTelemetryStore
    private let lock = NSLock()
    private var didFinish = false
    private var promptBuiltAt: DispatchTime?
    private var debounceScheduledAt: DispatchTime?
    private var debounceElapsedAt: DispatchTime?
    private var generationBeganAt: DispatchTime?
    private var generationEndedAt: DispatchTime?
    private var presentBeganAt: DispatchTime?

    init(context: TextFieldContext, telemetry: CompletionTelemetryStore) {
        id = OSSignpostID(log: Self.signpostLog)
        startedAt = DispatchTime.now()
        self.telemetry = telemetry
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "CompletionE2E",
            signpostID: id,
            "bundle=%{public}@ before_chars=%d after_chars=%d",
            context.target.bundleIdentifier as NSString,
            context.beforeCursor.count,
            context.afterCursor.count
        )
        eventAXSnapshot()
    }

    func eventAXSnapshot() {
        event("AXSnapshot")
    }

    func eventPromptBuilt(
        estimatedTokens: Int,
        sideContextReused: Bool,
        requiredPrefixBytes: Int,
        maxCompletionTokens: Int
    ) {
        guard canEmit else { return }
        promptBuiltAt = DispatchTime.now()
        os_signpost(
            .event,
            log: Self.signpostLog,
            name: "PromptBuilt",
            signpostID: id,
            "estimated_tokens=%d side_reused=%d required_prefix_bytes=%d max_completion_tokens=%d",
            estimatedTokens,
            sideContextReused ? 1 : 0,
            requiredPrefixBytes,
            maxCompletionTokens
        )
    }

    func eventWarmupScheduled() {
        event("AnchorWarmupScheduled")
    }

    func eventDebounceScheduled(nanoseconds: UInt64) {
        guard canEmit else { return }
        debounceScheduledAt = DispatchTime.now()
        os_signpost(
            .event,
            log: Self.signpostLog,
            name: "DebounceScheduled",
            signpostID: id,
            "delay_ms=%.2f",
            Double(nanoseconds) / 1_000_000.0
        )
    }

    func eventDebounceElapsed() {
        guard canEmit else { return }
        debounceElapsedAt = DispatchTime.now()
        event("DebounceElapsed")
    }

    func eventGenerationBegin() {
        guard canEmit else { return }
        generationBeganAt = DispatchTime.now()
        event("GenerationBegin")
    }

    func eventGenerationEnd(elapsedMs: Double, candidateCount: Int) {
        guard canEmit else { return }
        generationEndedAt = DispatchTime.now()
        os_signpost(
            .event,
            log: Self.signpostLog,
            name: "GenerationEnd",
            signpostID: id,
            "elapsed_ms=%.2f candidate_count=%d",
            elapsedMs,
            candidateCount
        )
    }

    func eventPresentBegin() {
        guard canEmit else { return }
        presentBeganAt = DispatchTime.now()
        event("PresentBegin")
    }

    func finish(outcome: String) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let promptBuiltAt = self.promptBuiltAt
        let debounceScheduledAt = self.debounceScheduledAt
        let debounceElapsedAt = self.debounceElapsedAt
        let generationBeganAt = self.generationBeganAt
        let generationEndedAt = self.generationEndedAt
        let presentBeganAt = self.presentBeganAt
        lock.unlock()

        let finishedAt = DispatchTime.now()
        let totalMillis = Self.millis(from: startedAt, to: finishedAt)
        os_signpost(
            .end,
            log: Self.signpostLog,
            name: "CompletionE2E",
            signpostID: id,
            "outcome=%{public}@ elapsed_ms=%.2f",
            outcome as NSString,
            totalMillis
        )

        // Only completions that were actually painted contribute to the visible-latency rollup. The
        // suppressed / cancelled / superseded paths are tracked separately by `suppressionReasons`
        // and aren't part of the user-perceived latency the Statistics pane reports.
        guard outcome == Self.shownOutcome,
              let promptBuiltAt,
              let debounceScheduledAt,
              let debounceElapsedAt,
              let generationBeganAt,
              let generationEndedAt,
              let presentBeganAt
        else { return }

        let sample = CompletionLatencySample(
            totalMillis: totalMillis,
            promptBuildMillis: Self.millis(from: startedAt, to: promptBuiltAt),
            debounceMillis: Self.millis(from: debounceScheduledAt, to: debounceElapsedAt),
            generationMillis: Self.millis(from: generationBeganAt, to: generationEndedAt),
            presentMillis: Self.millis(from: presentBeganAt, to: finishedAt)
        )
        telemetry.recordEndToEndSample(sample)
    }

    private var canEmit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !didFinish
    }

    private func event(_ name: StaticString) {
        guard canEmit else { return }
        os_signpost(.event, log: Self.signpostLog, name: name, signpostID: id)
    }

    private static func millis(from start: DispatchTime, to end: DispatchTime) -> Double {
        let delta = end.uptimeNanoseconds &- start.uptimeNanoseconds
        return Double(delta) / 1_000_000.0
    }
}

@MainActor
@Observable
final class CompletionController {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case unavailable(String)
    }

    private let tracker: AccessibilityContextTracker
    private let compatibilityStore: AppCompatibilityStore
    private let settings: SettingsStore
    private let history: WritingHistoryStoring
    private let screenTextProvider: ScreenTextProviding
    private let telemetry: CompletionTelemetryStore
    private let presenter: InlineGhostTextPresenter
    private let placementResolver: OverlayPlacementResolver
    private let overlayCalibrator: ScreenshotOverlayCalibrator
    private let inlineTextGeometry = TextRangeGeometryResolver()
    private let inlineFontMetrics = NSLayoutManager()
    private let inserter: PasteboardCompletionInserter
    private let filter: DefaultCandidateFilter
    private let frontmostBundleIdentifier: () -> String?
    private let engineBuilder: (
        AppCompatibilityStore,
        String,
        ThresholdAdjustments
    ) async throws -> ConstrainedGenerationEngine
    private let predictionLog = PredictionLog()
    private let fullPromptLog = FullPromptLog()
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "completion")

    private var engine: ConstrainedGenerationEngine?
    private var remoteGenerator: RemoteCompletionGenerator?
    private var activeRemoteConfiguration: RemoteCompletionConfiguration?
    private let documentMemory = DocumentMemoryStore()
    private var documentMemoryScope: URL?
    private var pinyinComposition = PinyinCompositionGate()
    private var pinyinInputSource: String?
    private var pinyinWindowID: CGWindowID?
    private var pinyinDocumentURL: URL?
    private var pinyinFocusElement: AXUIElement?
    private var pinyinProcess: pid_t?
    private let inferenceTasks = CompletionTaskRegistry()
    private var generationTask: CompletionTaskRegistry.Handle?
    private var debounceTask: Task<Void, Error>?
    private var warmupTask: CompletionTaskRegistry.Handle?
    private var loadTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var lifecycleRevision: UInt64 = 0
    private var isShuttingDown = false
    private var overlayCalibrationTask: Task<Void, Never>?
    private var overlayCalibrationInFlightKey: String?
    private var overlayCalibrationCache: [String: ScreenshotCalibrationResult] = [:]
    private var overlayCalibrationOrder: [String] = []
    private var listenerToken: UUID?
    private var activeLatencyTrace: CompletionLatencyTrace?
    private var fullPromptDebugByKey: [String: FullPromptDebugInfo] = [:]
    private var fullPromptDebugOrder: [String] = []
    /// Content signature of the last snapshot we acted on, so re-emitted snapshots whose text is
    /// unchanged (caret-geometry repolls) don't tear down and rebuild the overlay — that churn is
    /// what makes the ghost text flash.
    private var lastContextKey: String?
    /// Caret rect of the last snapshot we rendered the overlay against. Scrolling moves the caret on
    /// screen without changing the field text, so a same-text re-emit must re-pin the ghost text to
    /// the new caret position (auto-realign) instead of leaving it stranded where it was.
    private var lastCaretRect: CGRect?

    private(set) var loadState: LoadState = .idle
    private(set) var isRunning = false

    /// The model filename the current engine was (or is being) built from. Used to coalesce
    /// redundant `reloadModel()` calls — e.g. when a freshly downloaded model is auto-selected,
    /// `onModelReady` reloads explicitly *and* the Settings picker's `onChange` fires for the same
    /// programmatic selection. Set synchronously on the main actor before each load suspends, so the
    /// second call sees the target already active and no-ops.
    private var activeModelFilename: String?

    /// The completion currently shown as ghost text (the portion still ahead of the live caret).
    /// Nil when nothing is displayed. Exposed for the Tab acceptance controller / UI binding.
    private(set) var visibleCandidate: CompletionCandidate?

    /// The *anchor* of the live suggestion: the caret-reconciled completion text exactly as the
    /// model produced it for `anchorContext`. The text actually shown/inserted is re-derived from
    /// this against the *live* caret every keystroke (`liveCompletion(for:)`) — as the user types
    /// the suggested characters it shrinks, and when they diverge it is dropped. This is what keeps
    /// the overlay from going stale (and prevents the doubled-character bug where a suggestion
    /// generated for "…more " was inserted verbatim after the user had already typed "…more e").
    private var anchorText: String?
    private var anchorContext: TextFieldContext?
    private var suggestionObservation: CompletionTelemetryStore.SuggestionObservation?
    /// Reconciled, filter-approved candidate anchors from recent generations. Used to keep a
    /// lower-ranked branch alive when the user types into it, and to recover prior winning anchors
    /// after a small rollback such as deleting a typo. Bounded and string-only: no logits, KV state,
    /// or model branch memory are retained.
    private var reuseHistory = CompletionReuseHistory()
    /// The most recent focused-field context seen — the live caret the suggestion is reconciled to.
    private var latestContext: TextFieldContext?
    private var latestSnapshot: FocusedFieldSnapshot?
    private var lastRenderedStyle: ResolvedFieldStyle?
    private var frozenSideContext: FrozenPromptSideContext?
    private var lastGenerationLatencyMs: Double?
    /// Uptime of the previous request that reached model generation. Used only to recognize a
    /// cancellation-prone typing burst; it never delays the current request.
    private var lastGenerationRequestUptimeNanoseconds: UInt64?
    /// Set when the user accepts a word with Tab: keep the *rest* of the same suggestion in place and
    /// do not regenerate, so repeated Tab presses walk through the remaining words of that one
    /// completion. Cleared once the suggestion is exhausted, the user diverges, or the overlay is torn
    /// down — at which point normal per-keystroke generation resumes.
    private var holdAnchor = false
    private var awaitingWordCaret: TextFieldContext?
    /// Set after a macOS screenshot/screen-recording shortcut. While active, the already-visible
    /// overlay is preserved through transient capture focus changes, but acceptance is disabled until
    /// a real non-Screenshot focused-field snapshot revalidates the text/caret context.
    private var screenCaptureHold: ScreenCaptureHold?
    private var developerTuningHold = false
    var shouldSuppressForCorrection: ((TextFieldContext) -> Bool)?

    private struct ScreenCaptureHold {
        var originalBundleIdentifier: String?
    }

    var completionsEnabled = true {
        didSet {
            if !completionsEnabled { reset() }
        }
    }

    nonisolated static let fastDebounceNanoseconds: UInt64 = 15_000_000
    nonisolated static let moderateDebounceNanoseconds: UInt64 = 25_000_000
    nonisolated static let conservativeDebounceNanoseconds: UInt64 = 55_000_000
    private static let sideContextFreezeInterval: TimeInterval = 2.0
    private static let screenCaptureBundleIdentifiers: Set<String> = [
        "com.apple.screenshot.launcher"
    ]

    private struct FrozenPromptSideContext {
        var fieldKey: String
        var historyEnabled: Bool
        var clipboardEnabled: Bool
        var ocrEnabled: Bool
        var previousUserInputs: [String]
        var pasteboardText: String?
        var screenText: String?
        var lastUsedAt: Date

        func canReuse(
            fieldKey: String,
            historyEnabled: Bool,
            clipboardEnabled: Bool,
            ocrEnabled: Bool,
            now: Date
        ) -> Bool {
            self.fieldKey == fieldKey
                && self.historyEnabled == historyEnabled
                && self.clipboardEnabled == clipboardEnabled
                && self.ocrEnabled == ocrEnabled
                && now.timeIntervalSince(lastUsedAt) <= CompletionController.sideContextFreezeInterval
        }
    }

    init(
        tracker: AccessibilityContextTracker,
        settings: SettingsStore,
        history: WritingHistoryStoring = NullWritingHistoryStore(),
        screenTextProvider: ScreenTextProviding = NullScreenTextProvider(),
        telemetry: CompletionTelemetryStore = CompletionTelemetryStore(url: nil),
        compatibilityStore: AppCompatibilityStore = KeyTypeModuleGraph.makeCompatibilityStore(),
        overlayCalibrator: ScreenshotOverlayCalibrator = ScreenshotOverlayCalibrator(),
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        engineBuilder: ((
            AppCompatibilityStore,
            String,
            ThresholdAdjustments
        ) async throws -> ConstrainedGenerationEngine)? = nil
    ) {
        self.tracker = tracker
        self.settings = settings
        self.history = history
        self.screenTextProvider = screenTextProvider
        self.telemetry = telemetry
        self.compatibilityStore = compatibilityStore
        self.presenter = InlineGhostTextPresenter()
        self.placementResolver = OverlayPlacementResolver(compatibilityStore: compatibilityStore)
        self.overlayCalibrator = overlayCalibrator
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.engineBuilder = engineBuilder ?? { compatibilityStore, modelFilename, adjustments in
            try await Self.buildEngine(
                compatibilityStore: compatibilityStore,
                modelFilename: modelFilename,
                adjustments: adjustments
            )
        }
        self.inserter = PasteboardCompletionInserter(
            planner: InsertionPlanner(compatibilityStore: compatibilityStore)
        )
        // The in-beam guard (ADR-015) remains the primary typo defence, but it judges *healed,
        // pre-reconciliation* token paths — not the finalised string that is actually shown. Wiring
        // the synchronous recogniser into the output filter adds a cheap deterministic re-check of
        // the candidate as displayed (defense-in-depth on the real output). The check only runs on a
        // *closed* current word and is conservative, so it can't false-positive. See ADR-024.
        self.filter = DefaultCandidateFilter(
            compatibilityStore: compatibilityStore,
            wordRecognizer: SystemWordRecognizer()
        )
        settings.onDocumentMemoryChanged = { [weak self] in
            guard let self, self.remoteGenerator != nil else { return }
            self.reset()
            self.tracker.requestRefresh()
        }
    }

    // MARK: - Lifecycle

    /// Load the model + profile + engine once, off the main actor. Safe to call repeatedly.
    func loadIfNeeded() {
        guard !isShuttingDown, loadState == .idle else { return }
        if let config = settings.remoteCompletion {
            activeRemoteConfiguration = config
            activeModelFilename = nil
            do {
                remoteGenerator = try RemoteCompletionGenerator(configuration: config, apiKey: RemoteAPIKey.load(for: config))
                loadState = .ready
                tracker.requestRefresh()
            } catch {
                loadState = .unavailable(error.localizedDescription)
            }
            return
        }
        activeRemoteConfiguration = nil
        loadState = .loading
        // Tune the decoder from accumulated local telemetry (bounded nudges) and honor the chosen
        // model. Both are read now, on the main actor, before suspending into the off-main load.
        let adjustments = ThresholdTuner.adjustments(for: telemetry.snapshot())
        let modelFilename = settings.selectedModelFilename ?? ModelContainer.defaultModelFilename
        let revision = lifecycleRevision
        let engineBuilder = self.engineBuilder
        let compatibilityStore = self.compatibilityStore
        activeModelFilename = modelFilename
        loadTask = Task { [weak self] in
            do {
                let loadedEngine = try await engineBuilder(
                    compatibilityStore,
                    modelFilename,
                    adjustments
                )
                guard let self else {
                    await loadedEngine.shutdown()
                    return
                }
                guard !Task.isCancelled,
                      !self.isShuttingDown,
                      self.lifecycleRevision == revision,
                      self.activeModelFilename == modelFilename else {
                    // A model load can finish after cancellation because llama/Metal setup is not
                    // cancellation-aware. Never publish that late engine; dispose it in this task
                    // so shutdown can join the task and know its GPU resources are gone.
                    await loadedEngine.shutdown()
                    return
                }
                self.engine = loadedEngine
                self.loadState = .ready
                self.startStartupWarmup(engine: loadedEngine)
                self.log.info("Completion engine ready")
            } catch {
                guard let self,
                      !Task.isCancelled,
                      !self.isShuttingDown,
                      self.lifecycleRevision == revision else {
                    return
                }
                self.loadState = .unavailable("\(error)")
                self.log.error("Completion engine unavailable: \(error, privacy: .public)")
            }
        }
    }

    /// Tear down the current engine and reload from the currently selected model. Used after the
    /// user downloads/selects a different model so the change takes effect without relaunching.
    /// No-ops when the selected model is already the one loaded (or mid-load), so duplicate triggers
    /// (the post-download auto-select reloads *and* fires the picker's `onChange`) don't kick off two
    /// concurrent engine builds.
    func reloadModel() {
        guard !isShuttingDown else { return }
        let target = settings.selectedModelFilename ?? ModelContainer.defaultModelFilename
        guard settings.remoteCompletion != nil || activeRemoteConfiguration != nil ||
              target != activeModelFilename || loadState == .idle else { return }
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        activeModelFilename = target
        // Gate snapshots synchronously while the async drain is pending, so no new generation can
        // enter the registry between cancellation and engine teardown.
        loadState = .loading
        remoteGenerator = nil
        clearPinyinComposition()
        reset()
        lastGenerationLatencyMs = nil
        let pendingLoad = loadTask
        pendingLoad?.cancel()
        let previousReload = reloadTask
        previousReload?.cancel()
        reloadTask = Task { [weak self] in
            await previousReload?.value
            await pendingLoad?.value
            guard let self,
                  !Task.isCancelled,
                  !self.isShuttingDown,
                  self.lifecycleRevision == revision else {
                return
            }

            await self.inferenceTasks.cancelAllAndWait()
            guard !Task.isCancelled,
                  !self.isShuttingDown,
                  self.lifecycleRevision == revision else {
                return
            }

            // Transfer ownership before suspending so correction validation cannot acquire this
            // engine while it is being freed. Already-running engine work is serialized by the
            // runtime actor and the inference registry has been fully joined above.
            let engineToShutdown = self.engine
            self.engine = nil
            if let engineToShutdown {
                await engineToShutdown.shutdown()
            }
            guard !Task.isCancelled,
                  !self.isShuttingDown,
                  self.lifecycleRevision == revision else {
                return
            }
            self.loadState = .idle
            self.loadIfNeeded()
        }
    }

    func start() {
        guard !isShuttingDown, !isRunning else { return }
        isRunning = true
        loadIfNeeded()
        listenerToken = tracker.addListener { [weak self] snapshot in
            self?.handle(snapshot)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        clearPinyinComposition()
        if let listenerToken {
            tracker.removeListener(listenerToken)
        }
        listenerToken = nil
        overlayCalibrationTask?.cancel()
        overlayCalibrationTask = nil
        overlayCalibrationInFlightKey = nil
        reset()
    }

    /// Release the model/GPU resources before the app exits. Must complete before the process
    /// terminates: llama.cpp's ggml-metal backend asserts (and aborts) during its process-teardown
    /// destructors if the context/model — and thus the GPU residency sets — were never freed. We
    /// stop the pipeline, cancel and join every in-flight generation/load, then free the engine's
    /// native resources and drop our reference so its `deinit` can't race the same teardown. See
    /// ADR-021 and ADR-132.
    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        lifecycleRevision &+= 1
        stop()
        reset()
        let pendingLoad = loadTask
        let pendingReload = reloadTask
        pendingLoad?.cancel()
        pendingReload?.cancel()
        overlayCalibrationTask?.cancel()
        overlayCalibrationTask = nil
        lastGenerationLatencyMs = nil
        loadState = .idle
        activeModelFilename = nil
        remoteGenerator = nil
        activeRemoteConfiguration = nil
        let engineToShutdown = engine
        engine = nil

        // `cancel()` is only a request. A canceled warmup can still be blocked in
        // MTLCommandBuffer.waitUntilCompleted(), and a canceled load can still return a newly
        // allocated llama context. Join both classes of work before freeing the active engine or
        // allowing AppKit to call exit().
        await inferenceTasks.closeAndWait()
        await pendingReload?.value
        await pendingLoad?.value
        if let engineToShutdown {
            await engineToShutdown.shutdown()
        }
        loadTask = nil
        reloadTask = nil
    }

    // MARK: - Pipeline

    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        let hasMarkedText = remoteGenerator == nil ? nil : snapshot.flatMap { remoteMarkedText(in: $0) }
        let pinyinDecision = pinyinSnapshotDecision(for: snapshot, hasMarkedText: hasMarkedText)
        guard pinyinDecision != .blocked, pinyinDecision != .cancelled else { return }
        if hasMarkedText == true {
            if lastContextKey != nil || visibleCandidate != nil {
                predictionLog.append("WETYPE marked snapshot blocked")
            }
            invalidateDirectLatinEvidence()
            reset(keepingReuseHistory: true)
            return
        }
        // Conditions under which there can be no suggestion: tear everything down and reset.
        guard completionsEnabled, loadState == .ready, engine != nil || remoteGenerator != nil else { reset(); return }
        guard let snapshot else {
            latestSnapshot = nil
            if preserveDeveloperTuningOverlayForMissingSnapshot() { return }
            if preserveScreenCaptureHoldForMissingSnapshot() { return }
            reset()
            return
        }
        let scopedDocument = settings.documentMemoryEnabled && activeRemoteConfiguration?.supportsDocumentMemory == true
            ? snapshot.documentURL : nil
        if documentMemoryScope != scopedDocument {
            reset()
            documentMemoryScope = scopedDocument
        }
        latestSnapshot = snapshot
        if preserveDeveloperTuningOverlay(for: snapshot.context) { return }
        developerTuningHold = false
        if preserveScreenCaptureHold(for: snapshot.context) { return }
        let context = snapshot.context
        if let prior = awaitingWordCaret {
            if prior.target != context.target {
                clearCompletion()
            } else if prior.beforeCursor == context.beforeCursor,
                      prior.afterCursor == context.afterCursor,
                      prior.selection == context.selection {
                return
            }
        }
        guard let caretRect = snapshot.caretRect, !caretRect.isEmpty else {
            if awaitingWordCaret != nil { return }
            if preserveHeldCompletion(for: snapshot.context) { return }
            reset(keepingReuseHistory: true)
            return
        }

        let redrawAfterWord = awaitingWordCaret != nil
        awaitingWordCaret = nil
        latestContext = context
        let policy = compatibilityStore.policy(for: context)
        guard policy.isCompletionEnabled, !policy.excludesSecureField,
              // Live per-app disable from Settings (reflects runtime toggles without rebuilding the
              // compatibility store). See ADR-023.
              !settings.perAppDisabled.contains(context.target.bundleIdentifier),
              policy.allowsMidLineCompletion || context.afterCursor.isEmpty,
              policy.allowsTabAcceptance
        else { reset(); return }

        if remoteGenerator != nil,
           (!context.afterCursor.isEmpty || !(context.selection.selectedText ?? "").isEmpty) {
            reset()
            return
        }

        if shouldSuppressForCorrection?(context) == true {
            reset(keepingReuseHistory: true)
            return
        }

        // No usable prefix → don't generate (Cotypist's `emptyPrompt` gate). A base model given an
        // empty before-cursor just continues the prompt scaffolding (e.g. echoes section headers),
        // so there is nothing worth showing until the user has typed something at the caret.
        guard !context.beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { reset(); return }

        // Token healing is intentionally lexical. Numeric and mixed alphanumeric stems are exact-ID
        // territory, and the filters suppress them after generation; skip that decode up front.
        guard !MidWordHealing.shouldSuppressNumericMidWordStem(for: context)
        else {
            reset(keepingReuseHistory: true)
            return
        }

        // Skip identical re-emits — keep whatever is on screen, no flicker. The one exception is a
        // moved caret with unchanged text (e.g. the user scrolled the field): re-pin the visible
        // suggestion to the new caret rather than leaving it stranded at the old screen position.
        let key = Self.contextKey(for: context)
        if key == lastContextKey {
            let shouldResolveStyle = settings.screenshotCalibrationEnabled
                || (visibleCandidate != nil && Self.caretMoved(from: lastCaretRect, to: caretRect))
            let style = shouldResolveStyle ? FieldFontResolver.currentStyle() : nil
            if let style {
                refreshOverlayCalibration(for: snapshot, style: style)
            }
            if visibleCandidate != nil, Self.caretMoved(from: lastCaretRect, to: caretRect) {
                lastCaretRect = caretRect
                renderSuggestion(for: context, style: style ?? FieldFontResolver.currentStyle())
            }
            return
        }
        lastContextKey = key
        lastCaretRect = caretRect

        guard placementResolver.placement(for: context) != nil else {
            if preserveHeldCompletion(for: context, contextKey: key) { return }
            reset(keepingReuseHistory: true)
            return
        }

        activeLatencyTrace?.finish(outcome: "superseded")
        let latencyTrace = CompletionLatencyTrace(context: context, telemetry: telemetry)
        activeLatencyTrace = latencyTrace

        // Resolve the field font and foreground color now, on the main actor, before suspending
        // into generation, so the ghost text matches the field's typeface and color.
        let style = FieldFontResolver.currentStyle()
        refreshOverlayCalibration(for: snapshot, style: style)

        // Holding an accepted suggestion: while its remainder still applies to the live caret, keep it
        // on screen and skip regeneration so repeated Tab presses accept subsequent words of the SAME
        // completion (rather than producing a fresh one after each word). Once the remainder is
        // exhausted or the user diverges, fall through to a fresh generation below.
        //
        // This must run before reuse-history lookup: that path has a "remaining text must be at least
        // 3 characters" guard for speculative type-through, but word-by-word Tab acceptance must keep
        // valid short remainders such as "hi" or ".".
        if holdAnchor {
            if renderSuggestion(for: context, style: style, clearOnFailure: false) {
                if redrawAfterWord { predictionLog.append("WORD_CARET redrawn") }
                finishLatencyTrace(latencyTrace, outcome: "held-anchor")
                return
            }
            holdAnchor = false
        }

        // The context just changed (the dedup above let us through), so the on-screen suggestion is
        // from the *previous* caret. Try to reuse a recently generated candidate set: if the user
        // typed into any still-compatible branch (including a lower-ranked one), or rolled back to a
        // prior anchor after deleting a typo, re-anchor it and skip this decode. Otherwise drop the
        // stale ghost and let a fresh generation run below.
        switch applyReuseHistoryIfUseful(for: context, style: style) {
        case .reused:
            finishLatencyTrace(latencyTrace, outcome: "reuse-history")
            return
        case .mustRecompute:
            break
        case .notApplicable:
            renderSuggestion(for: context, style: style)
        }

        if let remoteGenerator {
            scheduleRemoteCompletion(
                using: remoteGenerator, snapshot: snapshot, style: style,
                pinyinDecision: pinyinDecision, latencyTrace: latencyTrace
            )
            return
        }
        guard let engine else { return }

        // Token healing (ADR-019): when the caret sits mid-word, prompt from the last clean token
        // boundary and constrain regeneration to the already-typed bytes, so the model can reach
        // the natural whole-word token (" great") instead of being stuck in a subword state where a
        // worse word (" greasy") outranks it. The re-emitted stem is stripped before display in
        // `present`. When there is no heal the request is the plain whole-prefix continuation.
        let heal = MidWordHealing.plan(for: context)
        let promptContext = heal.map { context.replacingBeforeCursor($0.head) } ?? context
        // Personalization, clipboard, and screen/OCR are all opt-in. Once a typing burst starts, the
        // optional side sections are frozen briefly so unrelated history/clipboard/OCR updates do
        // not rewrite the prompt prefix and destroy KV append reuse mid-burst.
        let (sideContext, sideContextReused) = promptSideContext(for: promptContext)
        let promptResult = KeyTypeModuleGraph.makePromptBuilder().buildPrompt(
            context: promptContext,
            customInstructions: settings.promptCustomInstructions(appInstructions: policy.customInstructions),
            previousUserInputs: sideContext.previousUserInputs,
            pasteboardText: sideContext.pasteboardText,
            screenText: sideContext.screenText,
            includeEnvironmentContext: policy.includesEnvironmentContext
        )
        let requiredPrefixBytes = heal.map { Array($0.heal.utf8) } ?? []
        // The re-emitted stem consumes display width and may consume one token before the usable
        // suffix starts. Keep the exact width slack, but cap token slack to avoid slow mid-word tails.
        let healSlack = heal?.heal.count ?? 0
        let healExtraTokens = healSlack > 0 ? 1 : 0
        // Completion length is user-configurable (Settings) and maps to the decoder's token/width budget.
        let length = settings.completionLength
        let configuredMaxCompletionTokens = Self.contextAwareCompletionTokenBudget(
            baseMaxCompletionTokens: length.maxCompletionTokens,
            healExtraTokens: healExtraTokens,
            context: context
        )
        let debounceNanoseconds = Self.adaptiveDebounceNanoseconds(
            lastGenerationLatencyMs: lastGenerationLatencyMs
        )
        let requestUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let elapsedSincePreviousRequest = lastGenerationRequestUptimeNanoseconds.map {
            requestUptimeNanoseconds &- $0
        }
        lastGenerationRequestUptimeNanoseconds = requestUptimeNanoseconds
        let maxCompletionTokens = Self.burstAwareCompletionTokenBudget(
            requestedMaxCompletionTokens: configuredMaxCompletionTokens,
            healExtraTokens: healExtraTokens,
            elapsedSincePreviousRequestNanoseconds: elapsedSincePreviousRequest,
            debounceNanoseconds: debounceNanoseconds,
            lastGenerationLatencyMs: lastGenerationLatencyMs
        )
        let request = CompletionRequest(
            context: context,
            prompt: promptResult.prompt,
            requiredPrefixBytes: requiredPrefixBytes,
            mode: policy.completionMode,
            maxCompletionTokens: maxCompletionTokens,
            maxDisplayWidth: length.maxDisplayWidth + healSlack
        )
        rememberFullPromptDebug(
            for: request,
            promptResult: promptResult,
            promptContext: promptContext,
            tokenHealing: heal.map { FullPromptTokenHealing(head: $0.head, heal: $0.heal) },
            sideContext: sideContext,
            sideContextReused: sideContextReused,
            policy: policy,
            completionLength: length,
            healSlack: healSlack
        )
        latencyTrace.eventPromptBuilt(
            estimatedTokens: promptResult.estimatedTokenCount,
            sideContextReused: sideContextReused,
            requiredPrefixBytes: requiredPrefixBytes.count,
            maxCompletionTokens: request.maxCompletionTokens
        )
        // Debounce: coalesce rapid keystrokes, and DON'T hide the current ghost up front — we
        // transition directly old → new (or → hidden) when generation finishes, so typing updates
        // the suggestion in place instead of blinking it out and back in.
        latencyTrace.eventDebounceScheduled(nanoseconds: debounceNanoseconds)
        generationTask?.cancel()
        debounceTask?.cancel()
        let debounceGate = Task {
            try await Task.sleep(nanoseconds: debounceNanoseconds)
            latencyTrace.eventDebounceElapsed()
        }
        debounceTask = debounceGate
        generationTask = inferenceTasks.start { [weak self] in
            guard let self else { return }
            do {
                latencyTrace.eventGenerationBegin()
                let start = DispatchTime.now()
                let candidates = try await engine.completions(for: request)
                try Task.checkCancellation()
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                latencyTrace.eventGenerationEnd(elapsedMs: elapsedMs, candidateCount: candidates.count)
                self.lastGenerationLatencyMs = elapsedMs
                self.telemetry.recordLatency(milliseconds: elapsedMs)
                try await debounceGate.value
                try Task.checkCancellation()
                self.present(candidates, request: request, style: style, latencyTrace: latencyTrace)
            } catch is CancellationError {
                debounceGate.cancel()
                // Superseded by a newer keystroke — leave the current ghost as-is.
                self.finishLatencyTrace(latencyTrace, outcome: "cancelled")
            } catch {
                debounceGate.cancel()
                self.log.error("Generation failed: \(error, privacy: .public)")
                self.finishLatencyTrace(latencyTrace, outcome: "generation-error")
            }
        }
        if generationTask == nil {
            debounceGate.cancel()
        }
    }

    /// Called at key-down, before the IME or host field updates its accessibility value.
    /// Candidate navigation and selection remain with the input method while this returns true.
    func handlePinyinKey(_ key: PinyinCompositionGate.Key, inputSource: String?) -> Bool {
        guard remoteGenerator != nil, completionsEnabled, isRunning else { return false }
        let application = NSWorkspace.shared.frontmostApplication
        let snapshot = tracker.currentSnapshot.flatMap {
            $0.context.target.bundleIdentifier == application?.bundleIdentifier ? $0 : nil
        }
        if pinyinProcess != application?.processIdentifier || pinyinInputSource != inputSource
            || pinyinFocusChanged(in: snapshot) {
            clearPinyinComposition()
        }
        let wasComposing = pinyinComposition.isComposing
        let allowsDirectLatin = PinyinCompositionGate.isWeType(inputSource)
        let context = snapshot?.context
        guard pinyinComposition.keyDown(
            key, before: context?.beforeCursor, after: context?.afterCursor, allowsDirectLatin: allowsDirectLatin
        ) else {
            return false
        }
        if !wasComposing {
            pinyinFocusElement = tracker.focusedElement
            pinyinProcess = application?.processIdentifier
            pinyinInputSource = inputSource
            pinyinWindowID = snapshot?.windowID
            pinyinDocumentURL = snapshot?.documentURL
            reset()
            predictionLog.append("PINYIN began")
        }
        switch key {
        case .candidateSelection, .space:
            predictionLog.append("PINYIN selection key")
            tracker.requestRefresh()
        case .cancel, .deleteBackward:
            tracker.requestRefresh()
        case .letter where allowsDirectLatin:
            tracker.requestRefresh()
        default:
            break
        }
        return true
    }

    private func pinyinSnapshotDecision(
        for snapshot: FocusedFieldSnapshot?, hasMarkedText: Bool?
    ) -> PinyinCompositionGate.SnapshotDecision {
        guard pinyinComposition.isComposing else { return .clear }
        let application = NSWorkspace.shared.frontmostApplication
        if pinyinProcess != application?.processIdentifier || pinyinFocusChanged(in: snapshot) {
            clearPinyinComposition()
            return .clear
        }
        guard let snapshot else { return .blocked }
        let context = snapshot.context
        let decision = pinyinComposition.observe(
            before: context.beforeCursor, after: context.afterCursor,
            hasSelection: !(context.selection.selectedText ?? "").isEmpty,
            hasMarkedText: hasMarkedText
        )
        switch decision {
        case .committed:
            predictionLog.append("PINYIN committed")
            clearPinyinComposition()
        case .committedLatin:
            predictionLog.append("WETYPE Latin committed")
        case .cancelled:
            clearPinyinComposition()
            lastContextKey = Self.contextKey(for: context)
        case .blocked, .clear:
            break
        }
        return decision
    }

    private func clearPinyinComposition() {
        pinyinComposition.reset()
        pinyinInputSource = nil
        pinyinWindowID = nil
        pinyinDocumentURL = nil
        pinyinProcess = nil
        pinyinFocusElement = nil
    }

    func invalidateDirectLatinEvidence() {
        pinyinComposition.invalidateDirectLatinEvidence()
    }

    private func pinyinFocusChanged(in snapshot: FocusedFieldSnapshot?) -> Bool {
        if let original = pinyinDocumentURL, let current = snapshot?.documentURL, original != current {
            return true
        }
        if let original = pinyinWindowID, let current = snapshot?.windowID, original != current {
            return true
        }
        guard let original = pinyinFocusElement, let current = tracker.focusedElement else { return false }
        return !CFEqual(original, current)
    }

    private func remoteMarkedText(in snapshot: FocusedFieldSnapshot) -> Bool? {
        if let marked = snapshot.hasMarkedText { return marked }
        // Some editors do not expose marked ranges. A visible WeType popup can confirm
        // composition in those editors. Its absence alone does not confirm a commit.
        guard PinyinCompositionGate.isWeType(SystemActiveInputMethodProvider.currentIdentifier()) else { return nil }
        let imeProcesses = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.tencent.inputmethod.wetype"
        ).map(\.processIdentifier))
        guard !imeProcesses.isEmpty,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return nil }
        let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let hasPopup = windows.contains { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, imeProcesses.contains(owner),
                  let level = window[kCGWindowLayer as String] as? Int, level >= popupLevel,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), !rect.isEmpty
            else { return false }
            return (window[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        return hasPopup ? true : nil
    }

    private func scheduleRemoteCompletion(
        using generator: RemoteCompletionGenerator,
        snapshot: FocusedFieldSnapshot,
        style: ResolvedFieldStyle,
        pinyinDecision: PinyinCompositionGate.SnapshotDecision,
        latencyTrace: CompletionLatencyTrace
    ) {
        let context = snapshot.context
        let length = settings.completionLength
        let request = CompletionRequest(
            context: context,
            prompt: "",
            mode: compatibilityStore.policy(for: context).completionMode,
            maxCompletionTokens: length.maxCompletionTokens,
            maxDisplayWidth: length.maxDisplayWidth
        )
        let debounceMilliseconds: UInt64 = pinyinDecision == .committed ? 60 : 250
        let debounce = debounceMilliseconds * 1_000_000
        let revision = lifecycleRevision
        let configuration = activeRemoteConfiguration
        let application = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let document = documentMemoryScope

        generationTask?.cancel()
        latencyTrace.eventPromptBuilt(
            estimatedTokens: 0, sideContextReused: false,
            requiredPrefixBytes: 0, maxCompletionTokens: request.maxCompletionTokens
        )
        latencyTrace.eventDebounceScheduled(nanoseconds: debounce)
        generationTask = inferenceTasks.start { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: debounce)
                try Task.checkCancellation()
                guard self.canUseRemoteSnapshot(snapshot, revision: revision, application: application),
                      self.isCurrentDocumentMemoryScope(document) else {
                    self.finishLatencyTrace(latencyTrace, outcome: "superseded")
                    return
                }
                latencyTrace.eventDebounceElapsed()
                var snippets: [String] = []
                if let document {
                    snippets = (try? await self.documentMemory.updateAndFind(
                        for: document, committedText: context.beforeCursor,
                        inlineContext: String(context.beforeCursor.suffix(RemoteCompletionGenerator.cursorContextLimit))
                    )) ?? []
                    try Task.checkCancellation()
                    guard self.canUseRemoteSnapshot(snapshot, revision: revision, application: application),
                          self.isCurrentDocumentMemoryScope(document) else {
                        self.finishLatencyTrace(latencyTrace, outcome: "superseded")
                        return
                    }
                }
                self.predictionLog.append(
                    "API generation started debounce_ms=\(debounceMilliseconds) document_snippets=\(snippets.count)"
                )
                latencyTrace.eventGenerationBegin()
                let start = DispatchTime.now()
                let candidates = try await generator.completions(for: request, documentSnippets: snippets)
                try Task.checkCancellation()
                guard self.canUseRemoteSnapshot(snapshot, revision: revision, application: application),
                      self.isCurrentDocumentMemoryScope(document) else {
                    self.predictionLog.append("API generation discarded: input changed")
                    self.finishLatencyTrace(latencyTrace, outcome: "superseded")
                    return
                }
                let elapsed = Self.elapsedMilliseconds(since: start)
                latencyTrace.eventGenerationEnd(elapsedMs: elapsed, candidateCount: candidates.count)
                self.telemetry.recordLatency(milliseconds: elapsed)
                self.present(candidates, request: request, style: style, latencyTrace: latencyTrace)
            } catch {
                let outcome = Task.isCancelled ? "cancelled" : "generation-error"
                self.predictionLog.append("API generation \(outcome)")
                self.finishLatencyTrace(latencyTrace, outcome: outcome)
                guard !Task.isCancelled, self.activeRemoteConfiguration == configuration else { return }
                self.log.error("API completion failed")
            }
        }
    }

    private func isCurrentDocumentMemoryScope(_ expected: URL?) -> Bool {
        guard expected == documentMemoryScope else { return false }
        guard let expected else { return true }
        return settings.documentMemoryEnabled && FocusedFieldReader.focusedSavedDocumentURL() == expected
    }

    func clearDocumentMemory() {
        settings.documentMemoryEnabled = false
        let store = documentMemory
        Task {
            do {
                try await store.clear()
            } catch {
                log.error("Could not clear local document memory")
            }
        }
    }

    private func canUseRemoteSnapshot(
        _ snapshot: FocusedFieldSnapshot, revision: UInt64, application: pid_t?
    ) -> Bool {
        guard let application, !pinyinComposition.isComposing,
              lifecycleRevision == revision, completionsEnabled, loadState == .ready,
              activeRemoteConfiguration == settings.remoteCompletion,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application,
              let current = tracker.currentSnapshot, current == snapshot,
              remoteMarkedText(in: current) != true else { return false }
        let target = current.context.target.bundleIdentifier
        let policy = compatibilityStore.policy(for: current.context)
        return policy.isCompletionEnabled && policy.allowsTabAcceptance && !policy.excludesSecureField &&
            !settings.perAppDisabled.contains(target)
    }

    private static func elapsedMilliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    func refreshVisibleSuggestion(using snapshot: FocusedFieldSnapshot?) {
        guard let snapshot,
              !Self.isKeyTypeTarget(snapshot.context.target),
              visibleCandidate != nil || anchorText != nil else {
            return
        }

        latestSnapshot = snapshot
        latestContext = snapshot.context
        lastContextKey = Self.contextKey(for: snapshot.context)
        lastCaretRect = snapshot.caretRect
        let style = lastRenderedStyle ?? FieldFontResolver.currentStyle()
        _ = renderSuggestion(for: snapshot.context, style: style)
    }

    func suppressVisibleCompletionForCorrection(context: TextFieldContext) {
        guard latestContext?.target == context.target || anchorContext?.target == context.target else {
            return
        }
        debounceTask?.cancel()
        generationTask?.cancel()
        finishActiveLatencyTrace(outcome: "correction-priority")
        lastContextKey = Self.contextKey(for: context)
        clearCompletion()
    }

    func refreshAfterCorrectionAccepted() {
        debounceTask?.cancel()
        generationTask?.cancel()
        finishActiveLatencyTrace(outcome: "correction-accepted")
        lastContextKey = nil
        holdAnchor = false
        clearCompletion()
    }

    func validateCorrectionCandidates(
        _ candidates: [CorrectionCandidate],
        target: CorrectionTarget,
        context: TextFieldContext
    ) async throws -> [CorrectionCandidate] {
        guard !isShuttingDown, loadState == .ready, let engine else { return [] }
        let prior = candidates.lazy.compactMap {
            self.reuseHistory.priorPredictedReplacement(
                prefixBeforeWord: target.prefixBeforeWord,
                replacement: $0.replacement
            )
        }.first
        let suffixWindow = Self.correctionSuffixWindow(from: target.suffixAfterWord)
        return try await engine.validateCorrectionCandidates(
            candidates,
            prefixBeforeWord: target.prefixBeforeWord,
            suffixWindow: suffixWindow,
            priorPredictionReplacement: prior,
            thresholds: CorrectionValidationThresholds()
        )
    }

    @discardableResult
    func showDeveloperPlacementProbeAtLatestSnapshot(text: String = " ghost text probe") -> Bool {
        showDeveloperPlacementProbe(using: latestSnapshot, text: text)
    }

    @discardableResult
    func showDeveloperPlacementProbe(using snapshot: FocusedFieldSnapshot?, text: String = " ghost text probe") -> Bool {
        guard settings.developerOverrideTuningEnabled else {
            predictionLog.append("PROBE suppress=developerTuningDisabled")
            return false
        }
        guard let snapshot else {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            predictionLog.append("PROBE suppress=noSnapshot axTrusted=\(AXIsProcessTrusted()) frontmost=\(frontmost)")
            clearCompletion()
            return false
        }
        guard !Self.isKeyTypeTarget(snapshot.context.target) else {
            predictionLog.append("PROBE suppress=keyTypeTarget")
            clearCompletion()
            return false
        }
        guard !text.isEmpty else {
            predictionLog.append("PROBE suppress=emptyText target=\(snapshot.context.target.bundleIdentifier)")
            clearCompletion()
            return false
        }
        guard let caretRect = snapshot.caretRect, !caretRect.isEmpty else {
            predictionLog.append("PROBE suppress=noCaret target=\(snapshot.context.target.bundleIdentifier)")
            clearCompletion()
            return false
        }
        guard placementResolver.placement(for: snapshot.context) != nil else {
            predictionLog.append("PROBE suppress=noPlacement target=\(snapshot.context.target.bundleIdentifier)")
            clearCompletion()
            return false
        }

        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "developer-probe")

        latestSnapshot = snapshot
        latestContext = snapshot.context
        lastContextKey = Self.contextKey(for: snapshot.context)
        lastCaretRect = caretRect
        anchorText = text
        anchorContext = snapshot.context
        suggestionObservation = nil
        holdAnchor = false
        screenCaptureHold = nil
        developerTuningHold = true

        let style = FieldFontResolver.currentStyle()
        refreshOverlayCalibration(for: snapshot, style: style)
        let shown = renderSuggestion(for: snapshot.context, style: style)
        if shown {
            predictionLog.append(
                "PROBE target=\(snapshot.context.target.bundleIdentifier) text=\"\(PredictionLog.escape(text))\""
            )
        }
        return shown
    }

    private func present(
        _ candidates: [CompletionCandidate],
        request: CompletionRequest,
        style: ResolvedFieldStyle,
        latencyTrace: CompletionLatencyTrace?
    ) {
        latencyTrace?.eventPresentBegin()
        let isRemote = remoteGenerator != nil
        let ctx = isRemote ? "[API]" : PredictionLog.contextTail(request.context.beforeCursor)
        let ranked = (isRemote ? [] : Array(candidates.prefix(5)))
            .map { "\"\(PredictionLog.escape($0.text))\"" }
            .joined(separator: " | ")

        guard let best = candidates.first else {
            telemetry.recordSuppressed(reason: "noCandidate")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" → SUPPRESS(noCandidate)")
            appendFullPromptLog(
                request: request,
                candidates: candidates,
                outcome: "suppressed",
                shownText: nil,
                suppressionReason: "noCandidate"
            )
            clearCompletion()
            finishLatencyTrace(latencyTrace, outcome: "suppressed-no-candidate")
            return
        }
        if let reason = filter.suppressionReason(for: best, request: request) {
            telemetry.recordSuppressed(reason: String(describing: reason))
            log.debug("Suppressed: \(String(describing: reason), privacy: .public)")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SUPPRESS(\(reason))")
            appendFullPromptLog(
                request: request,
                candidates: candidates,
                outcome: "suppressed",
                shownText: nil,
                suppressionReason: String(describing: reason)
            )
            clearCompletion()
            finishLatencyTrace(latencyTrace, outcome: "suppressed-\(reason)")
            return
        }

        // When the prompt was healed (ADR-019), the completion re-emits the already-typed stem
        // (" great today."); strip it back off so only the genuinely new text ("at today.") remains.
        guard let anchored = anchorText(for: best, request: request, applyingFilter: false) else {
            telemetry.recordSuppressed(reason: "emptyAfterBoundary")
            predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SUPPRESS(emptyAfterBoundary)")
            appendFullPromptLog(
                request: request,
                candidates: candidates,
                outcome: "suppressed",
                shownText: nil,
                suppressionReason: "emptyAfterBoundary"
            )
            clearCompletion()
            finishLatencyTrace(latencyTrace, outcome: "suppressed-empty-after-boundary")
            return
        }

        let observation = telemetry.makeSuggestionObservation()
        if !isRemote, let reuseSnapshot = makePromotionCache(from: candidates, request: request),
           let eviction = reuseHistory.record(reuseSnapshot, observation: observation) {
            predictionLog.append(
                "REUSE evict removed=\(eviction.removedEntries) remaining=\(eviction.remainingEntries)"
            )
        }
        if shouldSuppressForCorrection?(request.context) == true {
            clearCompletion()
            finishLatencyTrace(latencyTrace, outcome: "suppressed-correction-priority")
            return
        }
        anchorText = anchored
        anchorContext = request.context
        suggestionObservation = observation
        guard renderSuggestion(for: latestContext ?? request.context, style: style, clearOnFailure: false)
                || renderSuggestion(for: request.context, style: style) else {
            finishLatencyTrace(latencyTrace, outcome: "suppressed-presentation")
            return
        }
        predictionLog.append("PREDICT ctx=\"\(ctx)\" [\(ranked)] → SHOWN \"\(PredictionLog.escape(isRemote ? "[API]" : anchored))\"")
        appendFullPromptLog(
            request: request,
            candidates: candidates,
            outcome: "shown",
            shownText: anchored,
            suppressionReason: nil
        )
        finishLatencyTrace(latencyTrace, outcome: CompletionLatencyTrace.shownOutcome)
    }

    private func appendFullPromptLog(
        request: CompletionRequest,
        candidates: [CompletionCandidate],
        outcome: String,
        shownText: String?,
        suppressionReason: String?
    ) {
        guard settings.fullPromptLoggingEnabled else { return }
        let candidateDiagnostics = candidates.enumerated().map { index, candidate in
            let reason = filter.suppressionReason(for: candidate, request: request)
            return FullPromptCandidateDiagnostic(
                rank: index,
                text: candidate.text,
                passesFilter: reason == nil,
                suppressionReason: reason.map { String(describing: $0) }
            )
        }
        fullPromptLog.append(
            request: request,
            candidates: candidates,
            outcome: outcome,
            shownText: shownText,
            suppressionReason: suppressionReason,
            generationLatencyMs: lastGenerationLatencyMs,
            candidateDiagnostics: candidateDiagnostics,
            debugInfo: takeFullPromptDebug(for: request)
        )
    }

    private func rememberFullPromptDebug(
        for request: CompletionRequest,
        promptResult: PromptBuildResult,
        promptContext: TextFieldContext,
        tokenHealing: FullPromptTokenHealing?,
        sideContext: FrozenPromptSideContext,
        sideContextReused: Bool,
        policy: CompletionPolicy,
        completionLength: CompletionLength,
        healSlack: Int
    ) {
        guard settings.fullPromptLoggingEnabled else { return }
        let key = Self.fullPromptDebugKey(for: request)
        let debug = FullPromptDebugInfo(
            promptEstimatedTokenCount: promptResult.estimatedTokenCount,
            promptSections: promptResult.sections.map(FullPromptSectionSnapshot.init),
            promptContext: FullPromptContext(promptContext),
            tokenHealing: tokenHealing,
            sideContext: FullPromptSideContextSnapshot(
                reused: sideContextReused,
                historyEnabled: sideContext.historyEnabled,
                clipboardEnabled: sideContext.clipboardEnabled,
                ocrEnabled: sideContext.ocrEnabled,
                previousUserInputs: sideContext.previousUserInputs,
                pasteboardText: sideContext.pasteboardText,
                screenText: sideContext.screenText
            ),
            settings: FullPromptSettingsSnapshot(
                completionLength: completionLength.rawValue,
                englishStyleInstruction: EnglishVariant.promptInstruction(),
                fullPromptLoggingEnabled: settings.fullPromptLoggingEnabled,
                perAppDisabledBundleIdentifiers: Array(settings.perAppDisabled).sorted()
            ),
            policy: FullPromptPolicySnapshot(policy),
            requestBudget: FullPromptRequestBudgetSnapshot(
                baseMaxCompletionTokens: completionLength.maxCompletionTokens,
                actualMaxCompletionTokens: request.maxCompletionTokens,
                baseMaxDisplayWidth: completionLength.maxDisplayWidth,
                actualMaxDisplayWidth: request.maxDisplayWidth,
                healSlackCharacters: healSlack,
                requiredPrefixByteCount: request.requiredPrefixBytes.count
            )
        )
        fullPromptDebugByKey[key] = debug
        fullPromptDebugOrder.append(key)
        if fullPromptDebugOrder.count > 16 {
            let removed = fullPromptDebugOrder.removeFirst()
            fullPromptDebugByKey.removeValue(forKey: removed)
        }
    }

    private func takeFullPromptDebug(for request: CompletionRequest) -> FullPromptDebugInfo? {
        let key = Self.fullPromptDebugKey(for: request)
        fullPromptDebugOrder.removeAll { $0 == key }
        return fullPromptDebugByKey.removeValue(forKey: key)
    }

    private func anchorText(
        for candidate: CompletionCandidate,
        request: CompletionRequest,
        applyingFilter: Bool
    ) -> String? {
        if applyingFilter, filter.suppressionReason(for: candidate, request: request) != nil {
            return nil
        }

        let completion = request.requiredPrefixBytes.isEmpty
            ? candidate.text
            : MidWordHealing.strip(candidate.text, heal: String(decoding: request.requiredPrefixBytes, as: UTF8.self))

        // Re-align the leading whitespace against the prefix this was generated for (ADR-017 /
        // CaretBoundary). This reconciled text is the suggestion *anchor*; what is actually shown and
        // inserted is re-derived from it against the live caret.
        var anchored = CaretBoundary.reconcile(completion, beforeCursor: request.context.beforeCursor)
        // Drop trailing whitespace for an end-of-line append: a dangling space renders as a phantom
        // gap in the ghost text and inserts a stray separator on accept. Mid-line keeps it — there the
        // trailing space may be the genuine separator before the existing after-cursor text. See ADR-024.
        if request.context.afterCursor.isEmpty {
            while let last = anchored.last, last.isWhitespace { anchored.removeLast() }
        }
        return anchored.isEmpty ? nil : anchored
    }

    private func makePromotionCache(
        from candidates: [CompletionCandidate],
        request: CompletionRequest
    ) -> CompletionPromotionCache? {
        var seen = Set<String>()
        var entries: [CompletionPromotionCache.Entry] = []
        entries.reserveCapacity(candidates.count)

        for (rank, candidate) in candidates.enumerated() {
            guard let anchored = anchorText(for: candidate, request: request, applyingFilter: true),
                  seen.insert(anchored).inserted
            else { continue }
            entries.append(
                CompletionPromotionCache.Entry(
                    anchorText: anchored,
                    sourceRank: rank,
                    logProbability: candidate.logProbability
                )
            )
        }

        guard !entries.isEmpty else { return nil }
        return CompletionPromotionCache(anchorContext: request.context, entries: entries)
    }

    nonisolated static func adaptiveDebounceNanoseconds(lastGenerationLatencyMs: Double?) -> UInt64 {
        guard let latency = lastGenerationLatencyMs else { return moderateDebounceNanoseconds }
        if latency <= 70 { return fastDebounceNanoseconds }
        if latency <= 140 { return moderateDebounceNanoseconds }
        return conservativeDebounceNanoseconds
    }

    /// Native FIM is only displayable when the final candidate is at most two tokens. Decode one
    /// extra token so the engine can observe a stop/boundary instead of exposing a live branch at
    /// the depth cap. A healed request may need one additional token to re-emit the forced stem.
    /// End-of-line and paragraph-boundary contexts retain the user's configured append budget.
    nonisolated static func contextAwareCompletionTokenBudget(
        baseMaxCompletionTokens: Int,
        healExtraTokens: Int,
        context: TextFieldContext
    ) -> Int {
        let base = max(0, baseMaxCompletionTokens)
        let healing = max(0, healExtraTokens)
        guard shouldUseCapsule(for: context) else { return base + healing }
        return min(base, 3) + healing
    }

    /// During a burst that is arriving faster than the current presentation/decode horizon, run
    /// only the immediately useful four-token stage. This is compute staging, not a pre-decode
    /// sleep: generation still starts at once, and a stable interval retains the explicitly chosen
    /// Long budget. Healing slack is mandatory and therefore sits outside the four-token stage.
    nonisolated static func burstAwareCompletionTokenBudget(
        requestedMaxCompletionTokens: Int,
        healExtraTokens: Int,
        elapsedSincePreviousRequestNanoseconds: UInt64?,
        debounceNanoseconds: UInt64,
        lastGenerationLatencyMs: Double?
    ) -> Int {
        let requested = max(0, requestedMaxCompletionTokens)
        let healing = max(0, healExtraTokens)
        let immediateStage = 4 + healing
        guard requested > immediateStage,
              let elapsed = elapsedSincePreviousRequestNanoseconds else {
            return requested
        }

        let generationHorizon = UInt64(max(0, lastGenerationLatencyMs ?? 0) * 1_000_000)
        let burstHorizon = max(debounceNanoseconds, generationHorizon)
        return elapsed < burstHorizon ? immediateStage : requested
    }

    private func promptSideContext(
        for context: TextFieldContext,
        now: Date = Date()
    ) -> (FrozenPromptSideContext, reused: Bool) {
        let fieldKey = Self.sideContextFieldKey(for: context)
        if var cached = frozenSideContext,
           cached.canReuse(
               fieldKey: fieldKey,
               historyEnabled: settings.historyEnabled,
               clipboardEnabled: settings.clipboardEnabled,
               ocrEnabled: settings.ocrEnabled,
               now: now
           ) {
            cached.lastUsedAt = now
            frozenSideContext = cached
            return (cached, true)
        }

        let query = WritingHistoryQuery(
            bundleIdentifier: context.target.bundleIdentifier,
            domain: context.target.domain,
            typingContext: context.typingContext,
            language: context.detectedLanguage
        )
        let previousUserInputs = settings.historyEnabled
            ? history.samples(for: query)
            : []
        let pasteboardText = settings.clipboardEnabled
            ? NSPasteboard.general.string(forType: .string)
            : nil
        let screenText = settings.ocrEnabled
            ? screenTextProvider.latestScreenText
            : nil

        let frozen = FrozenPromptSideContext(
            fieldKey: fieldKey,
            historyEnabled: settings.historyEnabled,
            clipboardEnabled: settings.clipboardEnabled,
            ocrEnabled: settings.ocrEnabled,
            previousUserInputs: previousUserInputs,
            pasteboardText: pasteboardText,
            screenText: screenText,
            lastUsedAt: now
        )
        frozenSideContext = frozen
        return (frozen, false)
    }

    private nonisolated static func sideContextFieldKey(for context: TextFieldContext) -> String {
        [
            context.target.bundleIdentifier,
            context.target.domain ?? "",
            context.target.windowTitle ?? "",
            context.placeholder ?? "",
            context.labels.joined(separator: "\u{1F}"),
            context.detectedLanguage ?? "",
            context.typingContext ?? ""
        ].joined(separator: "\u{1E}")
    }

    private func startStartupWarmup(engine: ConstrainedGenerationEngine) {
        let context = TextFieldContext(
            beforeCursor: "The",
            target: AppTarget(bundleIdentifier: "com.pattonium.KeyType", appName: "KeyType"),
            detectedLanguage: "en"
        )
        let prompt = KeyTypeModuleGraph.makePromptBuilder().buildPrompt(context: context).prompt
        let request = CompletionRequest(
            context: context,
            prompt: prompt,
            mode: .prose,
            maxCompletionTokens: 1,
            maxDisplayWidth: 8
        )
        startWarmup(engine: engine, request: request)
    }

    private func startAnchorWarmup(engine: ConstrainedGenerationEngine, request: CompletionRequest) {
        startWarmup(engine: engine, request: request)
    }

    private func startWarmup(engine: ConstrainedGenerationEngine, request: CompletionRequest) {
        guard !isShuttingDown else { return }
        warmupTask?.cancel()
        warmupTask = inferenceTasks.start { [weak self] in
            do {
                try Task.checkCancellation()
                try await engine.warmUp(for: request)
            } catch is CancellationError {
                // Superseded by a newer focus/typing context.
            } catch {
                self?.log.debug("Warmup failed: \(error, privacy: .public)")
            }
        }
    }

    private enum ReuseHistoryApplication {
        case reused
        case mustRecompute
        case notApplicable
    }

    @discardableResult
    private func applyReuseHistoryIfUseful(
        for live: TextFieldContext,
        style: ResolvedFieldStyle,
        updateLatestContext: Bool = false
    ) -> ReuseHistoryApplication {
        guard !reuseHistory.isEmpty else { return .notApplicable }

        switch reuseHistory.decision(for: live) {
        case let .reuse(reuse):
            anchorText = reuse.anchorText
            anchorContext = reuse.anchorContext
            suggestionObservation = reuse.observation
            if updateLatestContext { latestContext = live }
            guard renderSuggestion(for: live, style: style, clearOnFailure: false) else {
                clearCompletion()
                return .mustRecompute
            }
            predictionLog.append(
                "REUSE \(reuse.kind.rawValue) snapshot=\(reuse.snapshotID) rank=\(reuse.sourceRank) remaining=\"\(PredictionLog.escape(reuse.remainingText))\""
            )
            return .reused

        case .miss(_, .noTypedDelta):
            return .notApplicable

        case let .miss(kind, reason):
            predictionLog.append("REUSE miss kind=\(kind.rawValue) reason=\(reason.rawValue)")
            clearCompletion()
            return .mustRecompute
        }
    }

    /// Renders the anchored suggestion (if any) against `live`: shows the portion still ahead of the
    /// caret at the live placement, or clears everything when the user has typed past / diverged from
    /// it. The single place the overlay is shown, so display always matches the live caret.
    @discardableResult
    private func renderSuggestion(
        for live: TextFieldContext,
        style: ResolvedFieldStyle,
        clearOnFailure: Bool = true
    ) -> Bool {
        guard let shown = liveCompletion(for: live), !shown.isEmpty,
              var placement = placementResolver.placement(for: live) else {
            if clearOnFailure {
                clearCompletion()
            }
            return false
        }
        // Mid-line fill-in-the-middle completions overlap the existing suffix when drawn as inline
        // ghost text, so present them in a capsule below the caret instead. End-of-line and
        // end-of-paragraph (suffix begins on the next line) completions append cleanly, so they keep
        // the inline ghost-text form.
        if placement.mode == .inline, Self.shouldUseCapsule(for: live) {
            placement.presentation = .capsule
        }
        let candidate = CompletionCandidate(text: shown, mode: .prose)
        let policy = compatibilityStore.policy(for: live)
        var effectiveStyle = Self.effectiveOverlayStyle(
            style,
            for: live,
            fontFallback: policy.overlayFontFallback
        )
        if style.font == nil,
           effectiveStyle.font != nil,
           let fontFallback = policy.overlayFontFallback {
            placement.fontSizeAdjustmentFactor *= fontFallback.sizeAdjustmentFactor
        }
        // Keep the original AX style for refreshes. A fitted size belongs to this text run only.
        lastRenderedStyle = style
        var measuredRun: CGRect?
        if !effectiveStyle.usesFontPointSize, placement.presentation == .inlineGhost,
           let sample = measuredTextBeforeCaret(in: live, placement: placement),
           let fitted = InlineGhostTextPresenter.fontMatchingRun(
               sample.text, bounds: sample.rect, preferredFont: effectiveStyle.font
           ) {
            effectiveStyle.font = fitted
            effectiveStyle.usesFontPointSize = true
            effectiveStyle.lineHeight = nil
            measuredRun = sample.rect
        }
        let calibrated = calibratedOverlayInputs(
            style: effectiveStyle,
            placement: placement,
            live: live
        )
        placement = calibrated.placement
        var overlayStyle = calibrated.style.overlayTextStyle
        overlayStyle.usesFontPointSize = calibrated.style.usesFontPointSize
        overlayStyle.inlineAnchor = nativeInlineTextAnchor(
            for: live, style: calibrated.style, placement: placement, measuredRun: measuredRun
        )
        if overlayStyle.inlineAnchor != nil {
            placement.horizontalOffset = 0
            placement.verticalOffset = { _ in 0 }
        }
        let mirrorContext = Self.textMirrorContext(for: live, placement: placement)
        let canUseTextMirror = GhostTextOverlayWindow.canUseTextMirror(
            placement: placement,
            mirrorContext: mirrorContext
        )
        let resolvedFont = InlineGhostTextPresenter.resolveFont(
            overlayStyle.font, placement: placement, usesFontPointSize: overlayStyle.usesFontPointSize
        )
        if !canUseTextMirror,
           GhostTextOverlayWindow.shouldSuppressMirrorOverflow(text: shown, font: resolvedFont, placement: placement) {
            predictionLog.append(
                "PLACE suppress=mirrorOverflow cursor=\(PredictionLog.rect(placement.cursorRect)) field=\(placement.fieldRect.map(PredictionLog.rect) ?? "nil")"
            )
            clearCompletion()
            return false
        }

        presenter.show(
            candidate: candidate,
            placement: placement,
            style: overlayStyle,
            mirrorContext: mirrorContext
        )
        guard presenter.isVisible else {
            if clearOnFailure { clearCompletion() } else { visibleCandidate = nil }
            return false
        }
        visibleCandidate = candidate
        predictionLog.append(
            "PLACE mode=\(placement.mode) cursor=\(PredictionLog.rect(placement.cursorRect)) field=\(placement.fieldRect.map(PredictionLog.rect) ?? "nil")"
        )
        if let anchor = overlayStyle.inlineAnchor, let bodyFont = calibrated.style.font {
            predictionLog.append(String(
                format: "ALIGN body_pt=%.2f ghost_pt=%.2f insertion_x=%.2f baseline_y=%.2f line_height=%.2f source=%@",
                Double(bodyFont.pointSize), Double(resolvedFont.pointSize),
                Double(anchor.insertionX), Double(anchor.baselineY), Double(anchor.lineHeight),
                measuredRun != nil ? "glyphWidth" : (effectiveStyle.usesFontPointSize ? "AXFont" : "calibration")
            ))
        } else if placement.mode == .inline, placement.presentation == .inlineGhost {
            let bodySize = effectiveStyle.usesFontPointSize ? effectiveStyle.font?.pointSize : nil
            predictionLog.append(
                "ALIGN fallback body_pt=\(bodySize.map { String(format: "%.2f", Double($0)) } ?? "unknown") "
                + "ghost_pt=\(String(format: "%.2f", Double(resolvedFont.pointSize))) "
                + "caret_quality=\(placement.cursorRectQuality.rawValue)"
            )
        }
        if let suggestionObservation {
            telemetry.recordShown(suggestionObservation)
        }
        return true
    }

    private func measuredTextBeforeCaret(
        in context: TextFieldContext, placement: OverlayPlacement
    ) -> (text: String, rect: CGRect)? {
        guard placement.cursorRectQuality == .exact || placement.cursorRectQuality == .derived,
              (context.selection.selectedText ?? "").isEmpty else { return nil }
        // A short printable suffix avoids unrelated paragraphs; the row and trailing
        // edge checks below reject rectangles spanning a soft wrap or another field.
        let suffix = context.beforeCursor.suffix(5).reversed().prefix {
            $0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " "
        }.reversed()
        let text = String(suffix)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let end = context.beforeCursor.count
        let descriptor = TextRangeDescriptor(container: .beforeCursor, startOffset: end - text.count, endOffset: end)
        guard let geometry = inlineTextGeometry.resolve(range: descriptor, context: context),
              geometry.quality == .exact else { return nil }
        let rect = geometry.rect
        let caret = placement.cursorRect
        let trailing = placement.isRightToLeft ? rect.minX : rect.maxX
        guard abs(trailing - caret.minX) <= 3,
              abs(rect.midY - caret.midY) <= max(2, caret.height * 0.2),
              abs(rect.height - caret.height) <= max(3, caret.height * 0.3) else { return nil }
        return (text, rect)
    }

    private func nativeInlineTextAnchor(
        for context: TextFieldContext, style: ResolvedFieldStyle, placement: OverlayPlacement, measuredRun: CGRect?
    ) -> InlineTextAnchor? {
        guard style.usesFontPointSize, let font = style.font,
              placement.mode == .inline, placement.presentation == .inlineGhost, !placement.isRightToLeft,
              placement.cursorRectQuality == .exact || placement.cursorRectQuality == .derived else { return nil }

        let caret = placement.cursorRect
        let height = inlineFontMetrics.defaultLineHeight(for: font)
        guard height > 0 else { return nil }

        var previousRect = measuredRun
        if previousRect == nil, let last = context.beforeCursor.last, !last.isWhitespace,
           (context.selection.selectedText ?? "").isEmpty {
            let end = context.beforeCursor.count
            let previous = TextRangeDescriptor(container: .beforeCursor, startOffset: end - 1, endOffset: end)
            if let geometry = inlineTextGeometry.resolve(range: previous, context: context),
               geometry.quality == .exact,
               geometry.rect.width > 0 {
                previousRect = geometry.rect
            }
        }

        return InlineTextAnchor.native(
            caret: caret,
            previousCharacter: previousRect,
            lineHeight: height,
            baselineFromTop: inlineFontMetrics.defaultBaselineOffset(for: font) - style.baselineOffset
        )
    }

    private func refreshOverlayCalibration(
        for snapshot: FocusedFieldSnapshot,
        style: ResolvedFieldStyle
    ) {
        guard settings.screenshotCalibrationEnabled,
              !Self.canUseReportedPointSize(style, for: snapshot.context),
              CGPreflightScreenCaptureAccess(),
              !snapshot.context.traits.isSecureTextEntry,
              !snapshot.context.traits.isPasswordField,
              !snapshot.context.traits.isPasswordManagerContext,
              let font = style.font,
              snapshot.context.geometry.cursorRect?.isEmpty == false else {
            overlayCalibrationTask?.cancel()
            overlayCalibrationTask = nil
            overlayCalibrationInFlightKey = nil
            return
        }

        let key = Self.overlayCalibrationKey(
            for: snapshot.context,
            style: style,
            windowID: snapshot.windowID
        )
        guard overlayCalibrationCache[key] == nil,
              overlayCalibrationInFlightKey != key else {
            return
        }

        overlayCalibrationTask?.cancel()
        overlayCalibrationInFlightKey = key
        let color = style.color
        overlayCalibrationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await overlayCalibrator.calibrate(
                    snapshot: snapshot,
                    font: font,
                    textColor: color
                )
                guard !Task.isCancelled else { return }
                overlayCalibrationInFlightKey = nil

                guard result.meetsQualityThresholds else {
                    predictionLog.append(
                        String(
                            format: "CALIBRATE reject confidence=%.3f rmse=%.3f size=%.2f",
                            Double(result.confidence),
                            Double(result.rmse),
                            Double(result.bestSize)
                        )
                    )
                    return
                }

                rememberOverlayCalibration(result, forKey: key)
                predictionLog.append(
                    String(
                        format: "CALIBRATE accept confidence=%.3f rmse=%.3f sizeFactor=%.3f verticalOffset=%.1f",
                        Double(result.confidence),
                        Double(result.rmse),
                        Double(result.fontSizeAdjustmentFactor),
                        Double(result.verticalAlignmentOffset)
                    )
                )

                if visibleCandidate != nil,
                   let latestContext,
                   Self.overlayCalibrationKey(
                       for: latestContext,
                       style: style,
                       windowID: snapshot.windowID
                   ) == key {
                    _ = renderSuggestion(for: latestContext, style: style, clearOnFailure: false)
                }
            } catch is CancellationError {
                overlayCalibrationInFlightKey = nil
            } catch {
                overlayCalibrationInFlightKey = nil
                log.debug("Screenshot calibration failed: \(error, privacy: .public)")
            }
        }
    }

    private func calibratedOverlayInputs(
        style: ResolvedFieldStyle,
        placement: OverlayPlacement,
        live: TextFieldContext
    ) -> (style: ResolvedFieldStyle, placement: OverlayPlacement) {
        guard !style.usesFontPointSize, let result = cachedOverlayCalibration(for: live, style: style) else {
            return (style, placement)
        }

        return Self.applyOverlayCalibration(result, style: style, placement: placement)
    }

    nonisolated static func applyOverlayCalibration(
        _ result: ScreenshotCalibrationResult,
        style: ResolvedFieldStyle,
        placement: OverlayPlacement
    ) -> (style: ResolvedFieldStyle, placement: OverlayPlacement) {
        var calibratedStyle = style
        if let font = style.font {
            let calibratedSize = min(72, max(6, font.pointSize * result.fontSizeAdjustmentFactor))
            calibratedStyle.font = NSFont(descriptor: font.fontDescriptor, size: calibratedSize)
                ?? NSFont.systemFont(ofSize: calibratedSize)
            calibratedStyle.usesFontPointSize = true
            if let lineHeight = style.lineHeight {
                calibratedStyle.lineHeight = max(1, lineHeight * result.fontSizeAdjustmentFactor)
            }
        }

        var calibratedPlacement = placement
        if result.verticalAlignmentOffset != 0 {
            // Apply the scorer's signed correction directly to the caret rect. The calibration
            // scorer compares rendered overlay text against the captured line prefix; in practice
            // inverting that signed correction over-raises inline ghost text in native and browser
            // fields after font-size calibration has been applied.
            calibratedPlacement.cursorRect = calibratedPlacement.cursorRect.offsetBy(
                dx: 0,
                dy: result.verticalAlignmentOffset
            )
        }
        return (calibratedStyle, calibratedPlacement)
    }

    private func cachedOverlayCalibration(
        for context: TextFieldContext,
        style: ResolvedFieldStyle
    ) -> ScreenshotCalibrationResult? {
        guard settings.screenshotCalibrationEnabled,
              let snapshot = latestSnapshot,
              snapshot.context.target.bundleIdentifier == context.target.bundleIdentifier else {
            return nil
        }
        let key = Self.overlayCalibrationKey(
            for: context,
            style: style,
            windowID: snapshot.windowID
        )
        guard let result = overlayCalibrationCache[key],
              result.meetsQualityThresholds else {
            return nil
        }
        return result
    }

    private func rememberOverlayCalibration(_ result: ScreenshotCalibrationResult, forKey key: String) {
        if overlayCalibrationCache[key] == nil {
            overlayCalibrationOrder.append(key)
        }
        overlayCalibrationCache[key] = result
        while overlayCalibrationOrder.count > 24 {
            let removed = overlayCalibrationOrder.removeFirst()
            overlayCalibrationCache.removeValue(forKey: removed)
        }
    }

    /// The portion of the anchored completion still ahead of the live caret, or `nil` when the
    /// suggestion no longer applies. Valid only while the user *extends* the anchor's prefix by
    /// typing the suggested characters: any deletion, caret jump, change to the text after the
    /// cursor, or a divergent keystroke invalidates it (returns `nil`).
    private func liveCompletion(for live: TextFieldContext) -> String? {
        guard let anchorText, let anchorContext else { return nil }
        return SuggestionAnchor.remaining(anchorText: anchorText, anchor: anchorContext, live: live)
    }

    private func preserveHeldCompletion(for context: TextFieldContext, contextKey: String? = nil) -> Bool {
        guard holdAnchor,
              let remaining = liveCompletion(for: context),
              !remaining.isEmpty
        else {
            return false
        }

        latestContext = context
        visibleCandidate = CompletionCandidate(text: remaining, mode: .prose)
        if let contextKey {
            lastContextKey = contextKey
            lastCaretRect = nil
        }
        return true
    }

    private func clearCompletion() {
        presenter.hide()
        visibleCandidate = nil
        anchorText = nil
        anchorContext = nil
        suggestionObservation = nil
        holdAnchor = false
        awaitingWordCaret = nil
        screenCaptureHold = nil
        developerTuningHold = false
        lastRenderedStyle = nil
    }

    private func finishLatencyTrace(_ trace: CompletionLatencyTrace?, outcome: String) {
        trace?.finish(outcome: outcome)
        if let trace, activeLatencyTrace === trace {
            activeLatencyTrace = nil
        }
    }

    private func finishActiveLatencyTrace(outcome: String) {
        activeLatencyTrace?.finish(outcome: outcome)
        activeLatencyTrace = nil
    }

    /// Hide any ghost text and forget the last context, so the next snapshot is treated as new.
    private func reset(keepingReuseHistory: Bool = false) {
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "reset")
        lastContextKey = nil
        lastCaretRect = nil
        frozenSideContext = nil
        lastGenerationRequestUptimeNanoseconds = nil
        latestSnapshot = nil
        if !keepingReuseHistory {
            reuseHistory.removeAll()
        }
        clearCompletion()
    }

    private func preserveDeveloperTuningOverlay(for context: TextFieldContext) -> Bool {
        guard settings.developerOverrideTuningEnabled,
              visibleCandidate != nil,
              Self.isKeyTypeTarget(context.target) else {
            return false
        }
        holdOverlayForDeveloperTuning()
        return true
    }

    private func preserveDeveloperTuningOverlayForMissingSnapshot() -> Bool {
        guard Self.shouldPreserveDeveloperTuningOverlayForMissingSnapshot(
            settingsEnabled: settings.developerOverrideTuningEnabled,
            hasVisibleCandidate: visibleCandidate != nil,
            developerTuningHold: developerTuningHold,
            frontmostBundleIdentifier: frontmostBundleIdentifier()
        ) else {
            return false
        }
        holdOverlayForDeveloperTuning()
        return true
    }

    nonisolated static func shouldPreserveDeveloperTuningOverlayForMissingSnapshot(
        settingsEnabled: Bool,
        hasVisibleCandidate: Bool,
        developerTuningHold: Bool,
        frontmostBundleIdentifier: String?
    ) -> Bool {
        guard settingsEnabled,
              hasVisibleCandidate,
              developerTuningHold,
              let frontmostBundleIdentifier else {
            return false
        }
        return isKeyTypeBundleIdentifier(frontmostBundleIdentifier)
    }

    private func holdOverlayForDeveloperTuning() {
        developerTuningHold = true
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "developer-tuning-hold")
    }

    private func preserveScreenCaptureHold(for context: TextFieldContext) -> Bool {
        guard screenCaptureHold != nil else { return false }
        guard visibleCandidate != nil else {
            screenCaptureHold = nil
            return false
        }
        if Self.isScreenCaptureBundleIdentifier(context.target.bundleIdentifier) {
            return true
        }
        // Any non-Screenshot text-field snapshot revalidates (or invalidates) the original context.
        // Let the normal pipeline handle it, with acceptance enabled again after this point.
        screenCaptureHold = nil
        return false
    }

    private func preserveScreenCaptureHoldForMissingSnapshot() -> Bool {
        guard let hold = screenCaptureHold else { return false }
        guard visibleCandidate != nil else {
            screenCaptureHold = nil
            return false
        }
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontmostBundleIdentifier,
           Self.isScreenCaptureBundleIdentifier(frontmostBundleIdentifier)
            || frontmostBundleIdentifier == hold.originalBundleIdentifier {
            return true
        }
        screenCaptureHold = nil
        return false
    }

    private static func isScreenCaptureBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        screenCaptureBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func isKeyTypeTarget(_ target: AppTarget) -> Bool {
        if isKeyTypeBundleIdentifier(target.bundleIdentifier) {
            return true
        }
        return target.appName.localizedCaseInsensitiveContains("KeyType")
    }

    private nonisolated static func isKeyTypeBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier.lowercased()
        if let ownBundleIdentifier = Bundle.main.bundleIdentifier?.lowercased(),
           normalized == ownBundleIdentifier {
            return true
        }
        return normalized.hasPrefix("com.pattonium.keytype")
    }

    private static func contextKey(for context: TextFieldContext) -> String {
        context.beforeCursor + "\u{1}" + context.afterCursor + "\u{1}" + context.target.bundleIdentifier
    }

    static func correctionSuffixWindow(from suffix: String) -> String {
        let trimmed = suffix.prefix(80)
        if let firstNonWhitespace = trimmed.first(where: { !$0.isWhitespace }),
           !firstNonWhitespace.isLetter,
           !firstNonWhitespace.isNumber {
            return ""
        }
        var result = ""
        var consumedWords = 0
        var inWord = false
        for character in trimmed {
            result.append(character)
            if character.isWhitespace {
                if inWord {
                    consumedWords += 1
                    if consumedWords >= 4 { break }
                }
                inWord = false
            } else {
                inWord = true
            }
        }
        return result
    }

    private static func overlayCalibrationKey(
        for context: TextFieldContext,
        style: ResolvedFieldStyle,
        windowID: CGWindowID?
    ) -> String {
        let field = context.geometry.fieldRect ?? context.geometry.cursorRect ?? .zero
        let font = style.font
        return [
            context.target.bundleIdentifier,
            context.target.domain ?? "",
            context.target.windowTitle ?? "",
            windowID.map(String.init) ?? "window:nil",
            rectKey(field),
            font?.fontName ?? "font:nil",
            font.map { String(format: "%.2f", Double($0.pointSize)) } ?? "size:nil",
            style.color.map(colorKey) ?? "color:nil"
        ].joined(separator: "\u{1D}")
    }

    private static func rectKey(_ rect: CGRect) -> String {
        String(
            format: "%.0f,%.0f,%.0f,%.0f",
            Double(rect.minX),
            Double(rect.minY),
            Double(rect.width),
            Double(rect.height)
        )
    }

    private static func colorKey(_ color: NSColor) -> String {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        return String(
            format: "%.2f,%.2f,%.2f,%.2f",
            Double(converted.redComponent),
            Double(converted.greenComponent),
            Double(converted.blueComponent),
            Double(converted.alphaComponent)
        )
    }

    private static func fullPromptDebugKey(for request: CompletionRequest) -> String {
        [
            request.prompt,
            contextKey(for: request.context),
            request.requiredPrefixBytes.map { String($0) }.joined(separator: ","),
            String(request.maxCompletionTokens),
            String(request.maxDisplayWidth)
        ].joined(separator: "\u{2}")
    }

    /// Whether the completion should render as a capsule below the caret rather than inline ghost
    /// text. True only when there is visible (non-whitespace) suffix text remaining on the *current*
    /// line — that's the case where inline ghost text would overlap the user's existing text. If the
    /// caret is at the end of the line, the document, or the end of a paragraph (the remainder of the
    /// line is empty/whitespace and the next character is a newline), inline ghost text appends
    /// cleanly with nothing to overlap, so we keep it.
    nonisolated static func shouldUseCapsule(for context: TextFieldContext) -> Bool {
        guard !context.geometry.isAtEndOfLine else { return false }
        let currentLineSuffix = context.afterCursor.prefix { !$0.isNewline }
        return currentLineSuffix.contains { !$0.isWhitespace }
    }

    nonisolated static func effectiveOverlayStyle(
        _ style: ResolvedFieldStyle,
        for context: TextFieldContext,
        fontFallback: OverlayFontFallback? = nil
    ) -> ResolvedFieldStyle {
        var result = style
        if context.target.bundleIdentifier == "md.obsidian" {
            result = ResolvedFieldStyle(font: nil, color: style.color)
        }
        result.usesFontPointSize = canUseReportedPointSize(result, for: context)

        guard result.font == nil, let fontFallback else { return result }
        switch fontFallback.design {
        case .monospaced:
            result.font = NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
        }
        return result
    }

    private nonisolated static func canUseReportedPointSize(
        _ style: ResolvedFieldStyle, for context: TextFieldContext
    ) -> Bool {
        guard style.usesFontPointSize, let font = style.font else { return false }
        if !context.traits.isWebField { return true }
        // A browser can report an unzoomed CSS size. Use it only when the measured caret agrees.
        guard context.geometry.cursorRectQuality == .exact, let height = context.geometry.cursorRect?.height else {
            return false
        }
        let lineHeight = style.lineHeight ?? ceil(font.ascender - font.descender + font.leading)
        return abs(height - lineHeight) <= max(2, lineHeight * 0.15)
    }

    nonisolated static func textMirrorContext(
        for context: TextFieldContext,
        placement: OverlayPlacement
    ) -> TextMirrorOverlayContext? {
        guard placement.mode == .mirror,
              placement.presentation == .inlineGhost,
              placement.fieldRect?.isEmpty == false else {
            return nil
        }
        return TextMirrorOverlayContext(
            beforeCursor: context.beforeCursor,
            afterCursor: context.afterCursor
        )
    }

    /// Whether the caret has shifted enough to warrant re-pinning the overlay. A small epsilon
    /// absorbs sub-pixel AX jitter so steady-state repolls don't churn the window.
    private static func caretMoved(from old: CGRect?, to new: CGRect) -> Bool {
        guard let old else { return true }
        let epsilon: CGFloat = 0.5
        return abs(old.minX - new.minX) > epsilon
            || abs(old.minY - new.minY) > epsilon
            || abs(old.height - new.height) > epsilon
    }

    // MARK: - Acceptance (driven by the Tab hotkey)

    func notePassedAcceptanceShortcut(reason: String) {
        guard remoteGenerator != nil else { return }
        predictionLog.append("ACCEPT shortcut passed: \(reason)")
    }

    /// True when there is a visible completion the user is allowed to accept with Tab.
    var canAcceptCompletion: Bool {
        guard !pinyinComposition.isComposing else { return false }
        guard screenCaptureHold == nil else { return false }
        guard !developerTuningHold else { return false }
        guard visibleCandidate != nil, let context = latestContext ?? anchorContext else { return false }
        guard isCurrentDocumentMemoryScope(documentMemoryScope) else { return false }
        return compatibilityStore.policy(for: context).allowsTabAcceptance
    }

    /// Called by the global key tap before passing macOS screenshot / screen-recording shortcuts
    /// through. The shortcut itself does not mutate the text field, so keep the current overlay in
    /// place for the capture. Acceptance stays disabled until a later focused-field snapshot proves
    /// the original context is active again.
    func prepareForScreenCaptureShortcut() {
        guard visibleCandidate != nil else { return }
        screenCaptureHold = ScreenCaptureHold(
            originalBundleIdentifier: (latestContext ?? anchorContext)?.target.bundleIdentifier
        )
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "screen-capture-hold")
    }

    /// Synchronously dismiss the on-screen suggestion when a just-pressed key makes it stale, *before*
    /// the AX `value-changed` snapshot for that keystroke arrives. Driven by the global key tap, which
    /// sees every key-down immediately; the AX pipeline that would otherwise clear a diverged
    /// suggestion lags behind by the debounce plus the app's notification latency, so without this the
    /// outdated ghost text visibly lingers for a beat after each key. See ADR-037.
    ///
    /// `mutation` describes the key's expected text effect. When the user is typing into any cached
    /// branch, the branch is promoted immediately and normal generation is skipped until the cache no
    /// longer has a substantial matching remainder. A plain backward delete can also recover an older
    /// cached anchor after a typo rollback. Anything else clears now and abandons in-flight generation,
    /// so a result returning for the previous caret can't re-show a stale suggestion.
    func dismissStaleCompletion(mutation: CompletionTextMutation, preservingPendingRemote: Bool = false) {
        // A key such as Tab may arrive while the server is still returning the first suggestion.
        // Keep the request alive until AX verifies whether this key moved focus or changed text.
        if remoteGenerator != nil {
            if preservingPendingRemote, mutation == .nonText, visibleCandidate == nil {
                tracker.requestRefresh()
            } else {
                generationTask?.cancel()
            }
        }
        guard let shown = visibleCandidate?.text, !shown.isEmpty else { return }
        switch mutation {
        case let .inserted(typed) where !typed.isEmpty:
            let historyWasAvailable = !reuseHistory.isEmpty
            if reuseCachedCompletion(typedCharacters: typed) { return }
            // Compatibility fallback for states created before a candidate-set cache exists.
            if !historyWasAvailable, shown.hasPrefix(typed), advanceTypeThrough(typedCharacters: typed) {
                return
            }

        case .deleteBackward:
            if recoverCachedCompletionAfterDeleteBackward() { return }

        case .deleteForward, .nonText, .inserted:
            break
        }

        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "stale-completion-dismissed")
        clearCompletion()
    }

    /// Backwards-compatible wrapper for older tests/call sites that only classify inserted text.
    func dismissStaleCompletion(typedCharacters typed: String?) {
        dismissStaleCompletion(mutation: typed.map(CompletionTextMutation.inserted) ?? .nonText)
    }

    private func reuseCachedCompletion(typedCharacters typed: String) -> Bool {
        guard !typed.isEmpty,
              let live = latestContext ?? anchorContext
        else { return false }
        let optimistic = live.replacingBeforeCursor(live.beforeCursor + typed)
        return reuseCachedCompletion(for: optimistic, kind: .append, immediateAcceptedHead: typed)
    }

    private func recoverCachedCompletionAfterDeleteBackward() -> Bool {
        guard let live = latestContext ?? anchorContext,
              !live.beforeCursor.isEmpty,
              (live.selection.selectedText ?? "").isEmpty
        else { return false }
        let optimistic = live.replacingBeforeCursor(String(live.beforeCursor.dropLast()))
        guard !reuseHistory.isEmpty else { return false }
        return applyCachedReuse(
            reuseHistory.decisionAfterDeleteBackward(for: optimistic),
            optimistic: optimistic,
            immediateAcceptedHead: nil
        )
    }

    private func reuseCachedCompletion(
        for optimistic: TextFieldContext,
        kind: CompletionReuseHistory.ReuseKind,
        immediateAcceptedHead: String?
    ) -> Bool {
        guard !reuseHistory.isEmpty else { return false }
        return applyCachedReuse(
            reuseHistory.decision(for: optimistic, preferredKind: kind),
            optimistic: optimistic,
            immediateAcceptedHead: immediateAcceptedHead
        )
    }

    private func applyCachedReuse(
        _ decision: CompletionReuseHistory.Decision,
        optimistic: TextFieldContext,
        immediateAcceptedHead: String?
    ) -> Bool {
        switch decision {
        case let .reuse(reuse):
            anchorText = reuse.anchorText
            anchorContext = reuse.anchorContext
            suggestionObservation = reuse.observation
            latestContext = optimistic
            let remainder = CompletionCandidate(text: reuse.remainingText, mode: .prose)
            visibleCandidate = remainder
            if let immediateAcceptedHead {
                presenter.advanceAfterAccepting(head: immediateAcceptedHead, remainder: remainder)
                if let suggestionObservation {
                    telemetry.recordShown(suggestionObservation)
                }
            }
            predictionLog.append(
                "REUSE \(reuse.kind.rawValue) snapshot=\(reuse.snapshotID) rank=\(reuse.sourceRank) remaining=\"\(PredictionLog.escape(reuse.remainingText))\""
            )
            debounceTask?.cancel()
            generationTask?.cancel()
            warmupTask?.cancel()
            finishActiveLatencyTrace(outcome: "cached-reuse")
            holdAnchor = false
            return true

        case .miss(_, .noTypedDelta):
            return false

        case let .miss(kind, reason):
            predictionLog.append("REUSE miss kind=\(kind.rawValue) reason=\(reason.rawValue)")
            return false
        }
    }

    /// The user typed the next visible ghost characters. AX will eventually report the real field
    /// state, but until then acceptance must see the optimistic caret so a rapid Tab does not insert
    /// characters the user already typed. Used only as a compatibility fallback when no candidate-set
    /// cache is available.
    private func advanceTypeThrough(typedCharacters typed: String) -> Bool {
        guard let live = latestContext ?? anchorContext,
              let anchorText,
              let anchorContext,
              let advanced = Self.typeThroughAdvance(
                  anchorText: anchorText,
                  anchorContext: anchorContext,
                  liveContext: live,
                  typedCharacters: typed
              ) else {
            return false
        }

        latestContext = advanced.context
        if advanced.remainingText.isEmpty {
            clearCompletion()
        } else {
            let remainder = CompletionCandidate(text: advanced.remainingText, mode: .prose)
            visibleCandidate = remainder
            presenter.advanceAfterAccepting(head: typed, remainder: remainder)
        }
        return true
    }

    nonisolated static func typeThroughAdvance(
        anchorText: String,
        anchorContext: TextFieldContext,
        liveContext: TextFieldContext,
        typedCharacters typed: String
    ) -> (context: TextFieldContext, remainingText: String)? {
        guard !typed.isEmpty,
              let current = SuggestionAnchor.remaining(
                  anchorText: anchorText,
                  anchor: anchorContext,
                  live: liveContext
              ),
              current.hasPrefix(typed) else {
            return nil
        }

        let optimistic = liveContext.replacingBeforeCursor(liveContext.beforeCursor + typed)
        guard let remaining = SuggestionAnchor.remaining(
            anchorText: anchorText,
            anchor: anchorContext,
            live: optimistic
        ) else {
            return nil
        }
        return (optimistic, remaining)
    }

    /// Tab: insert the next word or short Chinese phrase and keep the rest of the same completion
    /// in place for further Tab presses. We do **not** regenerate: the
    /// anchor stays put, the insertion-induced snapshot re-derives the shrinking remainder, and
    /// `holdAnchor` suppresses a fresh generation until the suggestion is exhausted or the user
    /// diverges. Native inline suggestions wait for the actual caret before showing the rest.
    func acceptNextWord() {
        guard canAcceptCompletion, let (text, context) = insertionText() else { return }
        let language = context.detectedLanguage
        let preferChinesePhrases = language?.hasPrefix("ja") != true && language?.hasPrefix("ko") != true
        let (head, rest) = NextWordSplitter.split(text, preferChinesePhrases: preferChinesePhrases)
        guard !head.isEmpty else { return }
        predictionLog.append(
            remoteGenerator != nil ? "ACCEPT(word) [API] characters=\(head.count) remaining=\(rest.count)" :
                "ACCEPT(word) \"\(PredictionLog.escape(head))\" of \"\(PredictionLog.escape(text))\""
        )

        holdAnchor = true
        if rest.isEmpty {
            reuseHistory.removeAll()
        }
        // Cancel any in-flight generation so it can't clobber the held suggestion when it returns.
        debounceTask?.cancel()
        generationTask?.cancel()
        warmupTask?.cancel()
        finishActiveLatencyTrace(outcome: "accepted-word")
        latestContext = context.replacingBeforeCursor(context.beforeCursor + head)
        let remainder = rest.isEmpty ? nil : CompletionCandidate(text: rest, mode: .prose)
        if remainder != nil, !context.traits.isWebField, !Self.shouldUseCapsule(for: context),
           let placement = placementResolver.placement(for: context),
           placement.mode == .inline, placement.presentation == .inlineGhost {
            awaitingWordCaret = context
            visibleCandidate = nil
            presenter.hide()
            predictionLog.append("WORD_CARET awaiting")
        } else {
            visibleCandidate = remainder
            presenter.advanceAfterAccepting(head: head, remainder: remainder)
        }
        insert(text: head, context: context, keepingAnchor: true)
    }

    /// Shift+Tab: insert the whole suggestion.
    func acceptFullCompletion() {
        guard canAcceptCompletion, let (text, context) = insertionText() else { return }
        predictionLog.append(remoteGenerator != nil ? "ACCEPT(full) [API]" : "ACCEPT(full) \"\(PredictionLog.escape(text))\"")
        insert(text: text, context: context)
    }

    /// The text to insert and the context to insert it into, derived from the anchored suggestion
    /// against the **live** caret (`liveCompletion(for:)`). Because the anchor already consumed any
    /// characters the user typed after the suggestion appeared, this never re-inserts already-typed
    /// text (no doubled characters) and never re-inserts a suggestion the user has diverged from.
    private func insertionText() -> (text: String, context: TextFieldContext)? {
        guard let live = latestContext ?? anchorContext,
              let text = liveCompletion(for: live), !text.isEmpty else { return nil }
        return (text, live)
    }

    /// Inserts `text` at the caret. By default (full-completion accept, or the final word) it drops
    /// the dedupe key and tears down the suggestion so the post-insertion snapshot regenerates fresh.
    /// When `keepingAnchor` is true (Tab word-acceptance with more words remaining) the anchor and
    /// overlay are left intact so the induced snapshot re-renders the shrinking remainder instead.
    private func insert(text: String, context: TextFieldContext, keepingAnchor: Bool = false) {
        guard !text.isEmpty else { return }
        let plan = inserter.planInsertion(candidate: CompletionCandidate(text: text), context: context)
        let observation = suggestionObservation
        if !keepingAnchor {
            // Drop the dedupe key so the post-insertion snapshot always regenerates a fresh suggestion.
            lastContextKey = nil
            reuseHistory.removeAll()
            clearCompletion()
        }
        Task {
            do {
                try await inserter.insert(plan: plan)
                if awaitingWordCaret == context {
                    tracker.requestRefresh()
                }
                telemetry.recordAccepted(observation)
            } catch {
                if awaitingWordCaret == context {
                    reset(keepingReuseHistory: true)
                    tracker.requestRefresh()
                }
                log.error("Insertion failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Engine construction

    /// Builds the runtime + profile + engine. Marked `nonisolated` so the heavy ~0.3 s model load
    /// runs off the main actor (the call site `await`s it from a `Task`) rather than hitching the
    /// UI. Inlined here — rather than via `KeyTypeModuleGraph`, whose helpers are main-actor
    /// isolated by default — so every step stays off main.
    nonisolated private static func buildEngine(
        compatibilityStore: AppCompatibilityStore,
        modelFilename: String,
        adjustments: ThresholdAdjustments
    ) async throws -> ConstrainedGenerationEngine {
        let modelURL = try ModelContainer.modelURL(filename: modelFilename)
        guard ModelContainer.modelExists(at: modelURL) else {
            throw CompletionLoadError.modelMissing(modelFilename)
        }
        // Batched beam-frontier decoding (ADR-043): the runtime holds the whole beam frontier in
        // parallel sequences and expands it in one `llama_decode` per depth level instead of one per
        // branch. This is the default and only decode path; `maxSequences` defaults to cover the
        // decoder's adaptive branch width.
        let runtime = try LlamaModelRuntime(modelURL: modelURL)
        // Resolve the tokenizer family from the model (catalog declaration, or derived from the
        // GGUF's vocab size for an imported model) so the profile filename + family validation match
        // what `ProfileGenerator` stamped. Catalog Qwen models keep the legacy "qwen3-v151936" family,
        // so an existing on-disk profile for the default model still loads without a rebuild.
        let family = ModelFamilyResolver.family(
            forFilename: modelFilename,
            vocabSize: runtime.metadata.vocabularySize
        )
        let profile = try MmapAutocompleteProfile.open(
            at: try ModelContainer.profileURL(family: family),
            tokenizerVocabSize: runtime.metadata.vocabularySize,
            tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
            expectedModelFamily: family
        )
        // Apply the telemetry-derived nudges to the decoder defaults: a larger relative cutoff keeps
        // more branches alive (fewer suppressions), a lower probability floor admits weaker-but-valid
        // continuations. Bounds are clamped inside `ThresholdTuner`. See ADR-023.
        let base = DecodingConfiguration(enableFillInMiddle: true)
        let configuration = DecodingConfiguration(
            relativeCutoff: base.relativeCutoff + adjustments.relativeCutoffDelta,
            minBranchProbability: base.minBranchProbability * adjustments.minBranchProbabilityScale,
            // Native fill-in-the-middle for mid-line completion (the on-device probe confirmed it
            // beats base continuation, which collides with the after-cursor text). Falls back to
            // base continuation when there is no suffix or the model lacks FIM tokens. See ADR-017.
            // The FIM-quality behaviors (caret-ward context windowing, suffix-overlap truncation, and
            // suffix-likelihood rerank) are always on and use the DecodingConfiguration defaults for
            // their window sizes / rerank depth+weight. See ADR-057.
            enableFillInMiddle: true
        )
        return ConstrainedGenerationEngine(
            runtime: runtime,
            profile: profile,
            compatibilityStore: compatibilityStore,
            configuration: configuration,
            wordRecognizer: SystemWordRecognizer()
        )
    }

    enum CompletionLoadError: Error, CustomStringConvertible {
        case modelMissing(String)

        var description: String {
            switch self {
            case let .modelMissing(name):
                return "Model file '\(name)' not found in Application Support/KeyType Dev/Models"
            }
        }
    }
}
