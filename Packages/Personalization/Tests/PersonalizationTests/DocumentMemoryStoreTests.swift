import Foundation
import Personalization
import XCTest

final class DocumentMemoryStoreTests: XCTestCase {
    func testSameFilenameRemainsIsolatedAcrossSwitchAndReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = URL(fileURLWithPath: "/tmp/editor-a/报告.txt")
        let second = URL(fileURLWithPath: "/tmp/editor-b/报告.txt")
        let query = "明天上午会把报告的修改意见发给"
        let a = "星槐老师负责审阅本报告的修改意见"
        let b = "青砾老师负责审阅本报告的修改意见"
        let store = DocumentMemoryStore(directory: folder, passphrase: "test-only")
        for (url, text) in [(first, a), (second, b), (first, a)] {
            let snippets = try await store.updateAndFind(for: url, committedText: text + "。\n" + query,
                                                          inlineContext: query)
            XCTAssertEqual(snippets, [text])
        }

        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            XCTAssertFalse(file.lastPathComponent.contains("报告"))
            let contents = try Data(contentsOf: file)
            XCTAssertNil(contents.range(of: Data(a.utf8)))
            XCTAssertNil(contents.range(of: Data(b.utf8)))
        }
        let reopened = DocumentMemoryStore(directory: folder, passphrase: "test-only")
        let snippets = try await reopened.updateAndFind(for: second, committedText: b + "。\n" + query,
                                                         inlineContext: query)
        XCTAssertEqual(snippets, [b])
        let afterEdit = try await reopened.updateAndFind(for: second, committedText: query,
                                                          inlineContext: query)
        XCTAssertTrue(afterEdit.isEmpty)
        try await reopened.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testSelectsThreeRelevantExcerptsOutsideTheInlineContext() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentMemoryStore(directory: folder, passphrase: "test-only")
        let url = URL(fileURLWithPath: "/tmp/budget.txt")
        let old = (1...5).map { "The harvest schedule item \($0) is due shortly." }.joined(separator: "\n")
        let visible = "The harvest schedule already includes this.\nUpdate the harvest schedule"
        let snippets = try await store.updateAndFind(for: url, committedText: old + "\n" + visible,
                                                       inlineContext: visible)
        XCTAssertEqual(snippets.count, 3)
        XCTAssertTrue(snippets.allSatisfy { $0.contains("is due shortly") })
    }

    func testCurrentSentenceOutranksAnUnrelatedNearbyParagraph() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentMemoryStore(directory: folder, passphrase: "test-only")
        let url = URL(fileURLWithPath: "/tmp/报告.txt")
        let fact = "明天上午统一把本报告的修改意见发给星槐老师审阅"
        let olderFiller = "附录保留表格和印刷规范，封面不需要插图"
        let nearby = "印刷规范沿用附录里的表格，封面插图需要更新。\n\n我明天上午会把修改意见发给"
        let snippets = try await store.updateAndFind(for: url,
                                                       committedText: fact + "。\n" + olderFiller + "。\n" + nearby,
                                                       inlineContext: nearby)
        XCTAssertEqual(snippets, [fact])
    }
}
