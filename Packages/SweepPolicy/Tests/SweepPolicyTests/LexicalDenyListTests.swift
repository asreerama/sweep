import XCTest
import SweepPolicy

/// `LexicalDenyList` is the prepared, per-walk form of `SweepPolicy.isDeniedLexically`; these
/// tests hold the two to identical answers over the shapes that historically bite lexical
/// denylists (case flips, decomposed Unicode, prefix-but-not-child names, trailing slashes), and
/// pin a handful of absolute expectations so the pair can never drift together into nonsense.
final class LexicalDenyListTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/fixture")

    private var denyList: LexicalDenyList {
        LexicalDenyList(volumeOf: URL(fileURLWithPath: "/"), home: home)
    }

    func testAgreesWithConvenienceOverTrickyShapes() {
        let candidates = [
            "/Users/fixture/Documents",
            "/Users/fixture/Documents/",
            "/Users/fixture/documents/taxes.pdf",
            "/Users/fixture/DocumentsBackup/file",
            "/Users/fixture/Desktop/screenshot.png",
            "/Users/fixture/Pictures/Photos Library.photoslibrary/originals/a.heic",
            "/Users/fixture/Library/Mobile Documents/com~apple~CloudDocs/f.txt",
            "/Users/fixture/Library/CloudStorage/Dropbox/f",
            "/Users/fixture/Library/Mail/V10/box",
            "/Users/fixture/Library/Caches/com.example.app/data",
            "/Users/fixture/Documents/re\u{0301}sume\u{0301}.pdf",
            "/System/Applications/Safari.app",
            "/System/ApplicationsX/impostor",
            "/tmp/scratch",
        ]
        let list = denyList
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            XCTAssertEqual(
                list.isDenied(url),
                SweepPolicy.isDeniedLexically(url, home: home),
                "prepared and per-call answers diverged at \(path)"
            )
        }
    }

    func testAbsoluteExpectations() {
        let list = denyList
        XCTAssertTrue(list.isDenied(URL(fileURLWithPath: "/Users/fixture/Documents/taxes.pdf")))
        XCTAssertTrue(list.isDenied(URL(fileURLWithPath: "/Users/fixture/Documents")))
        XCTAssertTrue(list.isDenied(URL(fileURLWithPath: "/System/Applications/Safari.app")))
        XCTAssertFalse(list.isDenied(URL(fileURLWithPath: "/Users/fixture/Library/Caches/x")))
        XCTAssertFalse(list.isDenied(URL(fileURLWithPath: "/Users/fixture/DocumentsBackup/x")),
                       "a sibling that merely shares the prefix string is not under the protected area")
    }

    func testStandardizedPathVariantMatchesURLVariant() {
        let list = denyList
        for path in ["/Users/fixture/Documents/a", "/Users/fixture/Library/Caches/b"] {
            XCTAssertEqual(
                list.isDenied(standardizedPath: path),
                list.isDenied(URL(fileURLWithPath: path))
            )
        }
    }
}
