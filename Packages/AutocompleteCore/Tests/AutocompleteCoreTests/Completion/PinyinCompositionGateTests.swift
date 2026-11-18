import AutocompleteCore
import XCTest

final class PinyinCompositionGateTests: XCTestCase {
    func testHoldsMarkedPinyinUntilChineseCandidateIsCommitted() {
        var gate = PinyinCompositionGate()
        XCTAssertTrue(gate.keyDown(.letter, before: "我会", after: ""))
        XCTAssertEqual(gate.observe(before: "我会fa'gei", after: "", hasSelection: false), .blocked)
        XCTAssertTrue(gate.keyDown(.other, before: "我会fa'gei", after: "")) // Tab stays with the IME
        XCTAssertTrue(gate.keyDown(.candidateSelection, before: nil, after: nil))
        XCTAssertEqual(gate.observe(before: "我会发gei", after: "", hasSelection: false), .blocked)
        XCTAssertEqual(gate.observe(before: "我会发给", after: "", hasSelection: true), .blocked)
        XCTAssertEqual(gate.observe(before: "我会发给", after: "", hasSelection: false), .committed)
        XCTAssertFalse(gate.keyDown(.other, before: nil, after: nil)) // Tab can accept once shown
    }

    func testEscapeDoesNotReleaseWhilePinyinIsStillMarked() {
        var gate = PinyinCompositionGate()
        XCTAssertTrue(gate.keyDown(.letter, before: "", after: ""))
        XCTAssertTrue(gate.keyDown(.cancel, before: nil, after: nil))
        XCTAssertEqual(gate.observe(before: "f", after: "", hasSelection: false), .blocked)
        XCTAssertEqual(gate.observe(before: "", after: "", hasSelection: false), .cancelled)
        XCTAssertFalse(gate.isComposing)
    }

    func testDoesNotInventCompositionOnCandidateKeys() {
        var gate = PinyinCompositionGate()
        XCTAssertFalse(gate.keyDown(.candidateSelection, before: "你好", after: ""))
        XCTAssertEqual(gate.observe(before: "你好", after: "", hasSelection: false), .clear)
        XCTAssertTrue(PinyinCompositionGate.isPinyinInputSource("com.tencent.inputmethod.wetype.pinyin"))
        XCTAssertFalse(PinyinCompositionGate.isPinyinInputSource("com.apple.keylayout.ABC"))
    }

    func testUnneededModelSpaceIsRemovedAtChineseBoundary() {
        XCTAssertEqual(CaretBoundary.reconcile(" 你。", beforeCursor: "发给"), "你。")
        XCTAssertEqual(CaretBoundary.reconcile(" you.", beforeCursor: "send"), " you.")
    }

    func testWeTypeCommitsDirectLatinWhenEditorReportsAnEmptyMarkedRange() {
        var gate = PinyinCompositionGate()
        XCTAssertTrue(gate.keyDown(.letter, before: "Please send ", after: "", allowsDirectLatin: true))
        XCTAssertEqual(
            gate.observe(before: "Please send m", after: "", hasSelection: false, hasMarkedText: false),
            .committedLatin
        )
        XCTAssertFalse(gate.isComposing)
    }

    func testMarkedWeTypePinyinHoldsEvenAfterSelectionUntilMarkClears() {
        var gate = PinyinCompositionGate()
        XCTAssertTrue(gate.keyDown(.letter, before: "请", after: "", allowsDirectLatin: true))
        XCTAssertEqual(gate.observe(before: "请fa gei", after: "", hasSelection: false, hasMarkedText: true), .blocked)
        XCTAssertTrue(gate.keyDown(.space, before: "请fa gei", after: ""))
        XCTAssertEqual(gate.observe(before: "请发gei", after: "", hasSelection: false, hasMarkedText: true), .blocked)
        XCTAssertEqual(gate.observe(before: "请发给", after: "", hasSelection: false, hasMarkedText: false), .committed)
        XCTAssertFalse(gate.isComposing)
    }

    func testWeTypeWithoutMarkedRangeRequiresActuallyInsertedSpace() {
        var gate = PinyinCompositionGate()
        XCTAssertTrue(gate.keyDown(.letter, before: "", after: "", allowsDirectLatin: true))
        XCTAssertEqual(gate.observe(before: "Please", after: "", hasSelection: false), .blocked)
        XCTAssertTrue(gate.keyDown(.space, before: "Please", after: ""))
        XCTAssertEqual(gate.observe(before: "Please", after: "", hasSelection: false), .blocked)
        XCTAssertEqual(gate.observe(before: "Please ", after: "", hasSelection: false), .committedLatin)

        XCTAssertTrue(gate.keyDown(.letter, before: "Please ", after: "", allowsDirectLatin: true))
        XCTAssertEqual(gate.observe(before: "Please s", after: "", hasSelection: false), .committedLatin)

        gate.invalidateDirectLatinEvidence()
        XCTAssertTrue(gate.keyDown(.letter, before: "Please send ", after: "", allowsDirectLatin: true))
        XCTAssertEqual(gate.observe(before: "Please send fa", after: "", hasSelection: false), .blocked)
    }

    func testCandidateSignalClearsPreviousWeTypeLatinEvidence() {
        var gate = PinyinCompositionGate()
        _ = gate.keyDown(.letter, before: "", after: "", allowsDirectLatin: true)
        _ = gate.keyDown(.space, before: "Please", after: "")
        XCTAssertEqual(gate.observe(before: "Please ", after: "", hasSelection: false), .committedLatin)
        _ = gate.keyDown(.letter, before: "Please ", after: "", allowsDirectLatin: true)
        XCTAssertEqual(gate.observe(before: "Please fa", after: "", hasSelection: false, hasMarkedText: true), .blocked)
        XCTAssertEqual(gate.observe(before: "Please fa", after: "", hasSelection: false), .blocked)
    }

    func testEmptyMarkDiscardsAnObsoletePrefixButUnknownDoesNot() {
        var gate = PinyinCompositionGate()
        _ = gate.keyDown(.letter, before: "旧文档", after: "", allowsDirectLatin: true)
        XCTAssertEqual(gate.observe(before: "Please s", after: "", hasSelection: false), .blocked)
        XCTAssertEqual(gate.observe(before: "Please s", after: "", hasSelection: false, hasMarkedText: false), .clear)
        XCTAssertFalse(gate.isComposing)
    }
}
