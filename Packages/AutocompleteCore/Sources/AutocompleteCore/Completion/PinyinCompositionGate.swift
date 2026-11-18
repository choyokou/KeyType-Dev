import Foundation

/// Holds completion while a Pinyin input source is editing marked text in another application.
/// A key starts the hold before AX observers can see the change. A selection key alone does not end
/// it: wait for a snapshot showing committed text because the AX value can temporarily contain Pinyin.
public struct PinyinCompositionGate {
    public enum Key {
        case letter, separator, deleteBackward, candidateSelection, space, cancel, other
    }

    public enum SnapshotDecision: Equatable {
        case clear, blocked, committed, committedLatin, cancelled
    }

    private struct Session {
        let before: String?
        let after: String?
        let allowsDirectLatin: Bool
        var typedKeys = 0
        var selectionRequested = false
        var cancellationRequested = false
        var prefixBeforeSpace: String?
    }

    private var session: Session?
    private var literalSpaceObserved = false

    public init() {}

    public var isComposing: Bool { session != nil }

    @discardableResult
    public mutating func keyDown(
        _ key: Key, before: String?, after: String?, allowsDirectLatin: Bool = false
    ) -> Bool {
        if session == nil {
            guard case .letter = key else { return false }
            session = Session(before: before, after: after, allowsDirectLatin: allowsDirectLatin)
        }
        switch key {
        case .letter, .separator:
            session?.typedKeys += 1
            session?.selectionRequested = false
            session?.cancellationRequested = false
            session?.prefixBeforeSpace = nil
        case .deleteBackward:
            let remaining = max(0, (session?.typedKeys ?? 1) - 1)
            session?.typedKeys = remaining
            session?.selectionRequested = false
            session?.cancellationRequested = remaining == 0
            session?.prefixBeforeSpace = nil
        case .space:
            session?.selectionRequested = true
            session?.prefixBeforeSpace = before
        case .candidateSelection:
            session?.selectionRequested = true
        case .cancel:
            session?.cancellationRequested = true
        case .other:
            break
        }
        return true
    }

    public mutating func observe(
        before: String, after: String, hasSelection: Bool, hasMarkedText: Bool? = nil
    ) -> SnapshotDecision {
        guard let session else { return .clear }
        if hasMarkedText == true {
            literalSpaceObserved = false
            return .blocked
        }
        guard !hasSelection else { return .blocked }
        guard session.after == nil || session.after == after else {
            return discardStaleSessionIfUnmarked(hasMarkedText)
        }
        if session.cancellationRequested && before == session.before {
            self.session = nil
            return .cancelled
        }
        guard session.allowsDirectLatin || session.selectionRequested else { return .blocked }
        let added: Substring
        if let baseline = session.before {
            guard before.hasPrefix(baseline) else { return discardStaleSessionIfUnmarked(hasMarkedText) }
            added = before.dropFirst(baseline.count)
        } else {
            added = before[...]
        }
        let inserted = String(added)
        let containsCJK = TextScriptProfile.containsCJK(in: inserted)
        let containsLatin = TextScriptProfile.containsLatinLetter(in: inserted)
        if session.allowsDirectLatin, !containsCJK {
            // Editors without a marked-range API can still prove a directly inserted ASCII space.
            // A Pinyin candidate-selection space is consumed by the IME and does not append it.
            if let prefix = session.prefixBeforeSpace, before == prefix + " ",
               TextScriptProfile.lastSubstantiveScript(in: prefix) == .latin {
                literalSpaceObserved = true
                self.session = nil
                return .committedLatin
            }
            if session.before != nil, containsLatin, hasMarkedText == false || literalSpaceObserved {
                self.session = nil
                return .committedLatin
            }
        }
        // Mixed text can be a partly converted candidate with a remaining Pinyin segment.
        guard session.selectionRequested else { return .blocked }
        guard containsCJK, !containsLatin else { return .blocked }
        self.session = nil
        literalSpaceObserved = false
        return .committed
    }

    public mutating func invalidateDirectLatinEvidence() {
        literalSpaceObserved = false
        session?.prefixBeforeSpace = nil
    }

    private mutating func discardStaleSessionIfUnmarked(_ hasMarkedText: Bool?) -> SnapshotDecision {
        guard hasMarkedText == false else { return .blocked }
        reset()
        return .clear
    }

    public mutating func reset() {
        session = nil
        literalSpaceObserved = false
    }

    public static func isWeType(_ identifier: String?) -> Bool {
        identifier?.lowercased() == "com.tencent.inputmethod.wetype.pinyin"
    }

    public static func isPinyinInputSource(_ identifier: String?) -> Bool {
        guard let identifier = identifier?.lowercased() else { return false }
        return identifier.contains("pinyin") || identifier == "com.apple.inputmethod.scim.itabc" ||
            identifier == "com.apple.inputmethod.scim.shuangpin"
    }
}
