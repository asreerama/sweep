import XCTest
@testable import SweepApp

/// Pure logic behind `LipoScreen`/`LipoService` (Toolbox "App Lipo" module): the fat-Mach-O header
/// parser, the savings estimate it feeds, and the protection/running predicate. None of this
/// touches the filesystem, spawns a process, or mutates anything — every fixture below is a
/// hand-built `Data` value standing in for a real executable's first bytes.
final class LipoLogicTests: XCTestCase {

    // MARK: - Byte-fixture builders

    private func appendUInt32(_ value: UInt32, bigEndian: Bool, into bytes: inout [UInt8]) {
        let b0 = UInt8((value >> 24) & 0xff), b1 = UInt8((value >> 16) & 0xff)
        let b2 = UInt8((value >> 8) & 0xff), b3 = UInt8(value & 0xff)
        bytes.append(contentsOf: bigEndian ? [b0, b1, b2, b3] : [b3, b2, b1, b0])
    }

    private func appendUInt64(_ value: UInt64, bigEndian: Bool, into bytes: inout [UInt8]) {
        let all = (0..<8).map { UInt8((value >> (56 - $0 * 8)) & 0xff) }
        bytes.append(contentsOf: bigEndian ? all : all.reversed())
    }

    /// A `fat_header` + `nfat_arch` `fat_arch` (32-bit) entries, in the byte order `magic`
    /// dictates — `bigEndian: true` reproduces a real Apple-toolchain fat binary; `false`
    /// reproduces the byte-swapped `FAT_CIGAM` case.
    private func fat32Fixture(
        magic: [UInt8], slices: [(cpuType: UInt32, offset: UInt32, size: UInt32)], bigEndian: Bool
    ) -> Data {
        var bytes = magic
        appendUInt32(UInt32(slices.count), bigEndian: bigEndian, into: &bytes)
        for slice in slices {
            appendUInt32(slice.cpuType, bigEndian: bigEndian, into: &bytes)
            appendUInt32(0, bigEndian: bigEndian, into: &bytes) // cpusubtype
            appendUInt32(slice.offset, bigEndian: bigEndian, into: &bytes)
            appendUInt32(slice.size, bigEndian: bigEndian, into: &bytes)
            appendUInt32(0x4000, bigEndian: bigEndian, into: &bytes) // align
        }
        return Data(bytes)
    }

    private func fat64Fixture(
        magic: [UInt8], slices: [(cpuType: UInt32, offset: UInt64, size: UInt64)], bigEndian: Bool
    ) -> Data {
        var bytes = magic
        appendUInt32(UInt32(slices.count), bigEndian: bigEndian, into: &bytes)
        for slice in slices {
            appendUInt32(slice.cpuType, bigEndian: bigEndian, into: &bytes)
            appendUInt32(0, bigEndian: bigEndian, into: &bytes) // cpusubtype
            appendUInt64(slice.offset, bigEndian: bigEndian, into: &bytes)
            appendUInt64(slice.size, bigEndian: bigEndian, into: &bytes)
            appendUInt32(0x4000, bigEndian: bigEndian, into: &bytes) // align
            appendUInt32(0, bigEndian: bigEndian, into: &bytes) // reserved
        }
        return Data(bytes)
    }

    private func thinFixture(magic: [UInt8], cpuType: UInt32, bigEndian: Bool) -> Data {
        var bytes = magic
        appendUInt32(cpuType, bigEndian: bigEndian, into: &bytes)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 20)) // rest of mach_header, unused
        return Data(bytes)
    }

    private let fatMagic: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
    private let fatCigam: [UInt8] = [0xBE, 0xBA, 0xFE, 0xCA]
    private let fat64Magic: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBF]
    private let fat64Cigam: [UInt8] = [0xBF, 0xBA, 0xFE, 0xCA]
    private let thinMagic64: [UInt8] = [0xFE, 0xED, 0xFA, 0xCF]
    private let thinCigam64: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]

    // MARK: - Fat-header parser

    func testFat32TwoSliceArm64AndX86_64() {
        let data = fat32Fixture(
            magic: fatMagic,
            slices: [
                (cpuType: LipoArch.arm64, offset: 16_384, size: 40_000_000),
                (cpuType: LipoArch.x86_64, offset: 40_020_000, size: 38_000_000),
            ],
            bigEndian: true
        )
        guard case .fat(let slices) = MachOFatParser.parse(data) else {
            return XCTFail("expected .fat")
        }
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].cpuType, LipoArch.arm64)
        XCTAssertEqual(slices[0].size, 40_000_000)
        XCTAssertEqual(slices[1].cpuType, LipoArch.x86_64)
        XCTAssertEqual(slices[1].size, 38_000_000)
    }

    func testFat64TwoSlice() {
        let data = fat64Fixture(
            magic: fat64Magic,
            slices: [
                (cpuType: LipoArch.arm64, offset: 16_384, size: 4_000_000_000),
                (cpuType: LipoArch.x86_64, offset: 4_020_000_000, size: 3_800_000_000),
            ],
            bigEndian: true
        )
        guard case .fat(let slices) = MachOFatParser.parse(data) else {
            return XCTFail("expected .fat")
        }
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].size, 4_000_000_000)
        XCTAssertEqual(slices[1].size, 3_800_000_000)
    }

    /// `FAT_CIGAM`/`FAT_CIGAM_64`: the literal byte-for-byte reverse of the standard magic,
    /// meaning the arch table that follows is little-endian instead of big-endian. The parser
    /// must still recover the correct slice sizes, not just recognize the magic.
    func testByteSwappedMagicIsParsedAsLittleEndian() {
        let data = fat32Fixture(
            magic: fatCigam,
            slices: [(cpuType: LipoArch.arm64, offset: 16_384, size: 12_345_678)],
            bigEndian: false
        )
        guard case .fat(let slices) = MachOFatParser.parse(data) else {
            return XCTFail("expected .fat")
        }
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].cpuType, LipoArch.arm64)
        XCTAssertEqual(slices[0].size, 12_345_678)
    }

    func testByteSwappedMagic64IsParsedAsLittleEndian() {
        let data = fat64Fixture(
            magic: fat64Cigam,
            slices: [(cpuType: LipoArch.x86_64, offset: 16_384, size: 987_654_321)],
            bigEndian: false
        )
        guard case .fat(let slices) = MachOFatParser.parse(data) else {
            return XCTFail("expected .fat")
        }
        XCTAssertEqual(slices[0].size, 987_654_321)
    }

    func testThinMachOIsRecognizedAsThinNotFat() {
        let data = thinFixture(magic: thinMagic64, cpuType: LipoArch.arm64, bigEndian: true)
        XCTAssertEqual(MachOFatParser.parse(data), .thin(cpuType: LipoArch.arm64))
    }

    func testThinMachOByteSwappedStillReadsTheRealCPUType() {
        // The literal on-disk pattern for a real little-endian (arm64/x86_64) 64-bit executable.
        let data = thinFixture(magic: thinCigam64, cpuType: LipoArch.x86_64, bigEndian: false)
        XCTAssertEqual(MachOFatParser.parse(data), .thin(cpuType: LipoArch.x86_64))
    }

    func testGarbageIsNeitherFatNorThin() {
        XCTAssertEqual(MachOFatParser.parse(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])), .notMachO)
        XCTAssertEqual(MachOFatParser.parse(Data("#!/bin/sh\nexit 0\n".utf8)), .notMachO)
    }

    func testTruncatedDataNeverCrashesAndReturnsNotMachO() {
        XCTAssertEqual(MachOFatParser.parse(Data()), .notMachO)
        XCTAssertEqual(MachOFatParser.parse(Data([0xCA, 0xFE])), .notMachO)
        // Claims two slices but supplies none: must fail safe, not read out of bounds.
        var truncated = fatMagic
        appendUInt32(2, bigEndian: true, into: &truncated)
        XCTAssertEqual(MachOFatParser.parse(Data(truncated)), .notMachO)
    }

    func testAbsurdArchCountIsRejected() {
        var bytes = fatMagic
        appendUInt32(UInt32.max, bigEndian: true, into: &bytes)
        XCTAssertEqual(MachOFatParser.parse(Data(bytes)), .notMachO)
    }

    // MARK: - Savings computation

    func testWastedBytesIsAllocatedSizeMinusNativeSlice() {
        let file = LipoFatFileMeasurement(
            allocatedSize: 100_000_000,
            slices: [
                MachOFatSlice(cpuType: LipoArch.arm64, offset: 0, size: 45_000_000),
                MachOFatSlice(cpuType: LipoArch.x86_64, offset: 45_000_000, size: 55_000_000),
            ]
        )
        XCTAssertEqual(LipoSavings.wastedBytes(file), 55_000_000)
    }

    func testWastedBytesIsNilWithNoNativeSlice() {
        let file = LipoFatFileMeasurement(
            allocatedSize: 50_000_000,
            slices: [MachOFatSlice(cpuType: LipoArch.x86_64, offset: 0, size: 50_000_000)]
        )
        XCTAssertNil(LipoSavings.wastedBytes(file))
    }

    func testWastedBytesNeverGoesNegative() {
        // Pathological but must not crash or report negative "savings": allocated size smaller
        // than the recorded slice size (e.g. a sparse/compressed file).
        let file = LipoFatFileMeasurement(
            allocatedSize: 10,
            slices: [
                MachOFatSlice(cpuType: LipoArch.arm64, offset: 0, size: 1_000),
                MachOFatSlice(cpuType: LipoArch.x86_64, offset: 1_000, size: 2_000),
            ]
        )
        XCTAssertEqual(LipoSavings.wastedBytes(file), 0)
    }

    func testSummarizeCombinesMainExecutableAndOtherFiles() {
        let mainSlices = [
            MachOFatSlice(cpuType: LipoArch.arm64, offset: 0, size: 40_000_000),
            MachOFatSlice(cpuType: LipoArch.x86_64, offset: 40_000_000, size: 38_000_000),
        ]
        let framework = LipoFatFileMeasurement(
            allocatedSize: 20_000_000,
            slices: [
                MachOFatSlice(cpuType: LipoArch.arm64, offset: 0, size: 9_000_000),
                MachOFatSlice(cpuType: LipoArch.x86_64, offset: 9_000_000, size: 11_000_000),
            ]
        )
        let measurement = LipoSummary.summarize(
            mainSlices: mainSlices, mainAllocatedSize: 78_000_000, otherFiles: [framework]
        )
        XCTAssertNotNil(measurement)
        XCTAssertEqual(measurement?.savingsBytes, 38_000_000 + 11_000_000)
        XCTAssertEqual(measurement?.architectures, ["arm64", "x86_64"])
    }

    func testSummarizeReturnsNilForThinMainExecutable() {
        let measurement = LipoSummary.summarize(
            mainSlices: [MachOFatSlice(cpuType: LipoArch.arm64, offset: 0, size: 40_000_000)],
            mainAllocatedSize: 40_000_000,
            otherFiles: []
        )
        XCTAssertNil(measurement)
    }

    func testSummarizeReturnsNilWhenMainExecutableHasNoNativeSlice() {
        // Fat, but neither slice is arm64 — not something this Mac can thin to its own arch.
        let measurement = LipoSummary.summarize(
            mainSlices: [
                MachOFatSlice(cpuType: LipoArch.x86_64, offset: 0, size: 30_000_000),
                MachOFatSlice(cpuType: 0x0000_0007, offset: 30_000_000, size: 10_000_000), // i386
            ],
            mainAllocatedSize: 40_000_000,
            otherFiles: []
        )
        XCTAssertNil(measurement)
    }

    func testSummarizeIgnoresAFrameworkWithNoNativeSliceRatherThanExcludingTheWholeApp() {
        let mainSlices = [
            MachOFatSlice(cpuType: LipoArch.arm64, offset: 0, size: 40_000_000),
            MachOFatSlice(cpuType: LipoArch.x86_64, offset: 40_000_000, size: 38_000_000),
        ]
        let oddFramework = LipoFatFileMeasurement(
            allocatedSize: 5_000_000,
            slices: [MachOFatSlice(cpuType: LipoArch.x86_64, offset: 0, size: 5_000_000)]
        )
        let measurement = LipoSummary.summarize(
            mainSlices: mainSlices, mainAllocatedSize: 78_000_000, otherFiles: [oddFramework]
        )
        // Only the main executable's own waste counts; the odd framework contributes nothing
        // (no arm64 slice to keep) but does not block the app from being listed.
        XCTAssertEqual(measurement?.savingsBytes, 38_000_000)
    }

    func testArchitectureOrderPutsNativeFirstThenFirstSeenOrder() {
        let mainSlices = [
            MachOFatSlice(cpuType: LipoArch.x86_64, offset: 0, size: 30_000_000),
            MachOFatSlice(cpuType: LipoArch.arm64, offset: 30_000_000, size: 20_000_000),
        ]
        let measurement = LipoSummary.summarize(mainSlices: mainSlices, mainAllocatedSize: 50_000_000, otherFiles: [])
        XCTAssertEqual(measurement?.architectures, ["arm64", "x86_64"])
    }

    // MARK: - Protection predicate

    func testAppleBundleIdentifierIsProtected() {
        XCTAssertTrue(LipoProtection.isProtected(
            bundlePath: URL(fileURLWithPath: "/Applications/Safari.app"), bundleIdentifier: "com.apple.Safari"
        ))
    }

    func testSystemLocationIsProtectedRegardlessOfIdentifier() {
        XCTAssertTrue(LipoProtection.isProtected(
            bundlePath: URL(fileURLWithPath: "/System/Applications/Preview.app"), bundleIdentifier: "com.example.preview"
        ))
    }

    func testOrdinaryThirdPartyAppIsNotProtected() {
        XCTAssertFalse(LipoProtection.isProtected(
            bundlePath: URL(fileURLWithPath: "/Applications/Firefox.app"), bundleIdentifier: "org.mozilla.firefox"
        ))
    }

    func testNilBundleIdentifierIsNotProtectedByItself() {
        XCTAssertFalse(LipoProtection.isProtected(
            bundlePath: URL(fileURLWithPath: "/Applications/Weird.app"), bundleIdentifier: nil
        ))
    }

    func testIsRunningMatchesAgainstTheSuppliedSet() {
        let path = "/Applications/Firefox.app"
        XCTAssertTrue(LipoProtection.isRunning(bundlePath: URL(fileURLWithPath: path), runningBundlePaths: [path]))
        XCTAssertFalse(LipoProtection.isRunning(
            bundlePath: URL(fileURLWithPath: path), runningBundlePaths: ["/Applications/Chrome.app"]
        ))
    }

    func testIsRunningWithEmptySetIsAlwaysFalse() {
        XCTAssertFalse(LipoProtection.isRunning(
            bundlePath: URL(fileURLWithPath: "/Applications/Firefox.app"), runningBundlePaths: []
        ))
    }
}
