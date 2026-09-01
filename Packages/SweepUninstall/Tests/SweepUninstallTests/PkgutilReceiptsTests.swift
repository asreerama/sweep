import XCTest
@testable import SweepUninstall

/// Regression coverage for finding #17 in the adversarial review: `ProcessRunner.run` previously
/// drained stdout to EOF before even starting to read stderr, with no timeout or output cap. A
/// fake executable is injected in place of real `pkgutil` so these tests don't depend on system
/// state and run in well under a second.
/// Thread-safe one-shot box for handing a caught `Error` back from a background queue to the
/// test's main thread without tripping Swift 6's `@Sendable`-closure-capture check on a plain
/// `var`.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func set(_ error: Error?) {
        lock.lock(); stored = error; lock.unlock()
    }

    var value: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

final class PkgutilReceiptsTests: XCTestCase {
    private func writeExecutableScript(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-fake-pkgutil-\(UUID().uuidString).sh")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The exact deadlock scenario the finding describes: the child writes a little to stdout
    /// (so stdout is "open" with data pending) then floods stderr forever without ever exiting.
    /// Draining stdout to EOF first (the pre-fix behavior) blocks forever here, because stdout is
    /// never closed — the child never exits — while stderr's pipe buffer fills and blocks the
    /// child's own `write()`, which is a real, reproducible deadlock, not a hypothetical one.
    func testDoesNotHangWhenChildFloodsStderrWhileHoldingStdoutOpen() throws {
        let script = try writeExecutableScript("""
        #!/bin/bash
        echo "partial stdout"
        while true; do echo "flood" >&2; done
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let expectation = expectation(description: "run returns instead of hanging")
        let errorBox = ErrorBox()
        DispatchQueue.global().async {
            do {
                _ = try ProcessRunner.run(script.path, [])
            } catch {
                errorBox.set(error)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)

        XCTAssertEqual(
            errorBox.value as? ProcessRunner.RunError,
            .outputLimitExceeded,
            "the stderr flood should hit the byte cap long before the 10s timeout"
        )
    }

    /// A child that neither exits nor produces enough output to hit the byte cap must still be
    /// bounded by the wall-clock timeout, not hang forever.
    func testTimesOutWhenChildNeitherExitsNorProducesOutput() throws {
        let script = try writeExecutableScript("""
        #!/bin/bash
        sleep 300
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let expectation = expectation(description: "run times out instead of hanging forever")
        let errorBox = ErrorBox()
        let start = Date()
        DispatchQueue.global().async {
            do {
                _ = try ProcessRunner.run(script.path, [], timeout: 1, outputByteLimit: ProcessRunner.defaultOutputByteLimit)
            } catch {
                errorBox.set(error)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "should return shortly after the configured 1s timeout, not wait for the child's own sleep")
        XCTAssertEqual(errorBox.value as? ProcessRunner.RunError, .timedOut)
    }

    func testUsesSanitizedEnvironmentAndFixedWorkingDirectory() throws {
        let script = try writeExecutableScript("""
        #!/bin/bash
        echo "$PATH"
        pwd
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let output = try ProcessRunner.run(script.path, [])
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "/usr/bin:/bin")
        XCTAssertEqual(lines.dropFirst().first, "/private/var/empty")
    }

    func testNormalOutputStillReturnsSuccessfully() throws {
        let script = try writeExecutableScript("""
        #!/bin/bash
        echo "line one"
        echo "line two" >&2
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let output = try ProcessRunner.run(script.path, [])
        XCTAssertEqual(output, "line one\n")
    }

    func testNonZeroExitStillSurfacesStderr() throws {
        let script = try writeExecutableScript("""
        #!/bin/bash
        echo "boom" >&2
        exit 7
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try ProcessRunner.run(script.path, [])
            XCTFail("expected a non-zero exit error")
        } catch ProcessRunner.RunError.nonZeroExit(let status, let stderr) {
            XCTAssertEqual(status, 7)
            XCTAssertEqual(stderr, "boom\n")
        }
    }
}
