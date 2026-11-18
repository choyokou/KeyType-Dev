import Foundation
@testable import MacContextCapture
import XCTest

final class SavedDocumentURLTests: XCTestCase {
    @MainActor
    func testSavedDocumentScopeUsesLocalPath() {
        let first = URL(fileURLWithPath: "/tmp/a/报告.txt")
        let second = URL(fileURLWithPath: "/tmp/b/报告.txt")
        XCTAssertNotEqual(FocusedFieldReader.normalizedSavedDocumentURL(first),
                          FocusedFieldReader.normalizedSavedDocumentURL(second))
        XCTAssertEqual(FocusedFieldReader.normalizedSavedDocumentURL(URL(string: "file://localhost/tmp/a/../a/report.txt")!),
                       URL(fileURLWithPath: "/tmp/a/report.txt").standardizedFileURL)
        XCTAssertNil(FocusedFieldReader.normalizedSavedDocumentURL(URL(string: "https://example.com/test.txt")!))
        XCTAssertNil(FocusedFieldReader.normalizedSavedDocumentURL(URL(string: "file://remote.example/test.txt")!))
    }
}
