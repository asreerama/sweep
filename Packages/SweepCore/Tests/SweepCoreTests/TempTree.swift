import Foundation
import XCTest

/// Disposable on-disk fixture tree. Deletion code is only ever pointed at one of these
/// (PLAN §6: fixtures on disposable storage until the safety audit signs off).
final class TempTree: Sendable {
    let root: URL

    init(_ label: String = "tree") throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "SweepCoreTests-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func write(_ relative: String, bytes: Int) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = Data(repeating: UInt8(ascii: "x"), count: bytes)
        try payload.write(to: target, options: .atomic)
        return target
    }

    @discardableResult
    func write(_ relative: String, contents: String) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: target, options: .atomic)
        return target
    }

    @discardableResult
    func hardLink(from existing: String, to link: String) throws -> URL {
        let target = url(link)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: url(existing), to: target)
        return target
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relative).path)
    }
}
