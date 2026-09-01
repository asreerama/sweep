import XCTest
@testable import SweepPolicy

final class PolicyTests: XCTestCase {
    func testProtectedAreasDenied() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "Documents/taxes.pdf")))
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "Library/CloudStorage/Dropbox/x")))
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "Library/Mail/V10/anything")))
        XCTAssertFalse(SweepPolicy.isDeniedLexically(home.appending(path: "Library/Caches/com.example.app")))
    }
}
