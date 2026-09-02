import SweepUI
import XCTest
@testable import SweepApp

/// Pure logic behind `PackagesScreen` (Toolbox "Packages" module): the `pkgutil --pkgs` and
/// `pkg-info-plist` parsers, the files-list parser and its absolute-path join, vendor grouping,
/// and the Apple-receipt filter. Nothing here spawns a `pkgutil` process or touches the
/// filesystem — `PackageIDsLoader`/`PackageReceiptDetailLoader`/`PackageFileExistenceChecker` are
/// thin, already-injectable I/O wrappers with nothing worth mocking, matching the "no Process
/// spawns in tests" scope this suite is asked for.
final class PackageReceiptsTests: XCTestCase {

    // MARK: - `pkgutil --pkgs` parser

    func testParsesOneIdentifierPerLine() {
        let output = "com.apple.pkg.Core\ncom.microsoft.OneDrive\ncom.tailscale.ipn.macsys\n"
        XCTAssertEqual(
            PackagePkgsParser.parse(output),
            ["com.apple.pkg.Core", "com.microsoft.OneDrive", "com.tailscale.ipn.macsys"]
        )
    }

    func testPkgsParserDropsBlankLines() {
        let output = "com.example.one\n\n\ncom.example.two\n"
        XCTAssertEqual(PackagePkgsParser.parse(output), ["com.example.one", "com.example.two"])
    }

    func testPkgsParserOnEmptyOutputIsEmpty() {
        XCTAssertTrue(PackagePkgsParser.parse("").isEmpty)
    }

    // MARK: - `pkgutil --files --only-files` parser

    func testFilesParserSplitsOnePathPerLine() {
        let output = "Applications/Foo.app/Contents/Info.plist\nApplications/Foo.app/Contents/MacOS/Foo\n"
        XCTAssertEqual(
            PackageFilesParser.parse(output),
            ["Applications/Foo.app/Contents/Info.plist", "Applications/Foo.app/Contents/MacOS/Foo"]
        )
    }

    func testFilesParserOnEmptyOutputIsEmpty() {
        XCTAssertTrue(PackageFilesParser.parse("").isEmpty)
    }

    // MARK: - `pkg-info-plist` parser (fixture plist Data)

    private func pkgInfoPlistData(
        installLocation: String? = "Applications",
        installTime: Int? = 1_700_000_000,
        version: String? = "1.2.3",
        volume: String? = "/"
    ) -> Data {
        var dict: [String: Any] = [:]
        if let installLocation { dict["install-location"] = installLocation }
        if let installTime { dict["install-time"] = installTime }
        if let version { dict["pkg-version"] = version }
        if let volume { dict["volume"] = volume }
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    func testParsesAllFourFields() {
        let info = PackagePkgInfoParser.parse(plistData: pkgInfoPlistData())
        XCTAssertEqual(info?.installLocation, "Applications")
        XCTAssertEqual(info?.version, "1.2.3")
        XCTAssertEqual(info?.volume, "/")
        XCTAssertEqual(info?.installDate, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testMissingInstallLocationDefaultsToEmptyString() {
        let info = PackagePkgInfoParser.parse(plistData: pkgInfoPlistData(installLocation: nil))
        XCTAssertEqual(info?.installLocation, "")
    }

    func testMissingVolumeDefaultsToRoot() {
        let info = PackagePkgInfoParser.parse(plistData: pkgInfoPlistData(volume: nil))
        XCTAssertEqual(info?.volume, "/")
    }

    func testMissingVersionIsNilNotEmptyString() {
        let info = PackagePkgInfoParser.parse(plistData: pkgInfoPlistData(version: nil))
        XCTAssertNil(info?.version)
    }

    func testMissingInstallTimeIsNilDate() {
        let info = PackagePkgInfoParser.parse(plistData: pkgInfoPlistData(installTime: nil))
        XCTAssertNil(info?.installDate)
    }

    func testMalformedPlistDataParsesToNil() {
        let garbage = Data("not a plist".utf8)
        XCTAssertNil(PackagePkgInfoParser.parse(plistData: garbage))
    }

    // MARK: - Absolute-path join

    func testJoinWithRootInstallLocationAndRootVolume() {
        // Real `pkgutil` output for a receipt installed straight to the volume root.
        let path = PackageFilePathJoiner.absolutePath(
            volume: "/",
            installLocation: "/",
            relativePath: "Applications/Foo.app/Contents/Info.plist"
        )
        XCTAssertEqual(path, "/Applications/Foo.app/Contents/Info.plist")
    }

    func testJoinWithApplicationsInstallLocationAndRootVolume() {
        let path = PackageFilePathJoiner.absolutePath(
            volume: "/",
            installLocation: "/Applications",
            relativePath: "Foo.app/Contents/Info.plist"
        )
        XCTAssertEqual(path, "/Applications/Foo.app/Contents/Info.plist")
    }

    func testJoinToleratesNoLeadingSlashOnInstallLocation() {
        // Real-machine `pkgutil` output never puts a leading slash on install-location.
        let path = PackageFilePathJoiner.absolutePath(
            volume: "/",
            installLocation: "Applications",
            relativePath: "Foo.app/Contents/Info.plist"
        )
        XCTAssertEqual(path, "/Applications/Foo.app/Contents/Info.plist")
    }

    func testJoinWithNonRootVolume() {
        let path = PackageFilePathJoiner.absolutePath(
            volume: "/Volumes/External",
            installLocation: "Applications",
            relativePath: "Foo.app/Foo"
        )
        XCTAssertEqual(path, "/Volumes/External/Applications/Foo.app/Foo")
    }

    func testJoinWithEmptyRelativePathReturnsTheInstallDirectoryItself() {
        let path = PackageFilePathJoiner.absolutePath(volume: "/", installLocation: "Applications", relativePath: "")
        XCTAssertEqual(path, "/Applications")
    }

    func testJoinNeverProducesADoubleSlash() {
        let path = PackageFilePathJoiner.absolutePath(
            volume: "/",
            installLocation: "/Library/Caches/x/",
            relativePath: "/Foo.app/Foo"
        )
        XCTAssertFalse(path.contains("//"))
        XCTAssertEqual(path, "/Library/Caches/x/Foo.app/Foo")
    }

    // MARK: - File-entry building + existence marking

    func testFileEntriesAreMarkedMissingViaInjectedExistenceCheck() {
        let entries = PackageFileEntryBuilder.buildEntries(
            relativePaths: ["Foo.app/Contents/Info.plist", "Foo.app/Contents/MacOS/Foo"],
            volume: "/",
            installLocation: "Applications",
            fileExists: { $0 == "/Applications/Foo.app/Contents/Info.plist" }
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].exists, true)
        XCTAssertEqual(entries[0].absolutePath, "/Applications/Foo.app/Contents/Info.plist")
        XCTAssertEqual(entries[1].exists, false)
        XCTAssertEqual(entries[1].absolutePath, "/Applications/Foo.app/Contents/MacOS/Foo")
    }

    // MARK: - Bounded file-list display

    func testVisibleFilesCollapsedShowsOnlyThePreviewCount() {
        let files = (0..<300).map { PackageFileEntry(absolutePath: "/f\($0)", relativePath: "f\($0)", exists: true) }
        let visible = PackageFileListDisplay.visibleFiles(files, expanded: false)
        XCTAssertEqual(visible.count, PackageFileListDisplay.previewCount)
    }

    func testVisibleFilesExpandedCapsAtTheRenderCeiling() {
        let files = (0..<300).map { PackageFileEntry(absolutePath: "/f\($0)", relativePath: "f\($0)", exists: true) }
        let visible = PackageFileListDisplay.visibleFiles(files, expanded: true)
        XCTAssertEqual(visible.count, PackageFileListDisplay.renderCap)
    }

    func testRemainderCountAfterExpansionReflectsWhatTheCapDropped() {
        let files = (0..<300).map { PackageFileEntry(absolutePath: "/f\($0)", relativePath: "f\($0)", exists: true) }
        XCTAssertEqual(PackageFileListDisplay.remainderCount(files, expanded: true), 100)
    }

    func testRemainderCountIsZeroWhenEverythingFits() {
        let files = (0..<10).map { PackageFileEntry(absolutePath: "/f\($0)", relativePath: "f\($0)", exists: true) }
        XCTAssertEqual(PackageFileListDisplay.remainderCount(files, expanded: false), 0)
    }

    // MARK: - Vendor grouping

    func testVendorDisplayNameIsTheSecondReverseDNSComponentCapitalized() {
        XCTAssertEqual(PackageVendor.displayName(forPackageID: "com.microsoft.OneDrive"), "Microsoft")
        XCTAssertEqual(PackageVendor.displayName(forPackageID: "com.tailscale.ipn.macsys"), "Tailscale")
        XCTAssertEqual(PackageVendor.displayName(forPackageID: "com.nordvpn.macos"), "Nordvpn")
    }

    func testVendorDisplayNameFallsBackToOtherForATooShortIdentifier() {
        XCTAssertEqual(PackageVendor.displayName(forPackageID: "sweep"), PackageVendor.fallbackName)
        XCTAssertEqual(PackageVendor.displayName(forPackageID: ""), PackageVendor.fallbackName)
    }

    func testBuildGroupsSortsVendorsAlphabeticallyAndReceiptsWithinAVendor() {
        let ids = [
            "com.microsoft.OneDrive",
            "com.adobe.acrobat.reader.installer",
            "com.microsoft.package.Microsoft_Excel.app",
            "com.tailscale.ipn.macsys",
        ]
        let groups = PackageVendorGrouping.buildGroups(from: ids)
        XCTAssertEqual(groups.map(\.vendorName), ["Adobe", "Microsoft", "Tailscale"])

        let microsoft = groups.first { $0.vendorName == "Microsoft" }
        XCTAssertEqual(
            microsoft?.receipts.map(\.id),
            ["com.microsoft.OneDrive", "com.microsoft.package.Microsoft_Excel.app"]
        )
    }

    func testBuildGroupsOnEmptyInputIsEmpty() {
        XCTAssertTrue(PackageVendorGrouping.buildGroups(from: []).isEmpty)
    }

    func testGroupFilteredByFoldedQueryMatchesOnId() {
        let groups = PackageVendorGrouping.buildGroups(from: ["com.microsoft.OneDrive", "com.microsoft.Word"])
        let group = groups[0]
        let filtered = group.filtered(byFoldedQuery: SearchFold.fold("onedrive"))
        XCTAssertEqual(filtered?.receipts.map(\.id), ["com.microsoft.OneDrive"])
    }

    func testGroupFilteredByFoldedQueryReturnsNilWhenNothingMatches() {
        let groups = PackageVendorGrouping.buildGroups(from: ["com.microsoft.OneDrive"])
        XCTAssertNil(groups[0].filtered(byFoldedQuery: SearchFold.fold("zzz-no-match")))
    }

    func testGroupFilteredByEmptyQueryReturnsEverything() {
        let groups = PackageVendorGrouping.buildGroups(from: ["com.microsoft.OneDrive", "com.microsoft.Word"])
        XCTAssertEqual(groups[0].filtered(byFoldedQuery: "")?.receipts.count, 2)
    }

    // MARK: - Apple-receipt filter

    func testExcludingAppleCountsAndDropsOnlyAppleReceipts() {
        let ids = [
            "com.apple.pkg.Core",
            "com.microsoft.OneDrive",
            "com.apple.pkg.XProtectPlistConfigData",
            "com.tailscale.ipn.macsys",
        ]
        let (kept, appleCount) = ApplePackageFilter.excludingApple(ids)
        XCTAssertEqual(kept, ["com.microsoft.OneDrive", "com.tailscale.ipn.macsys"])
        XCTAssertEqual(appleCount, 2)
    }

    func testExcludingAppleOnAllThirdPartyIdsHidesNothing() {
        let ids = ["com.microsoft.OneDrive", "com.tailscale.ipn.macsys"]
        let (kept, appleCount) = ApplePackageFilter.excludingApple(ids)
        XCTAssertEqual(kept, ids)
        XCTAssertEqual(appleCount, 0)
    }

    func testIsAppleReceiptMatchesTheBareIdentifierToo() {
        XCTAssertTrue(ApplePackageFilter.isAppleReceipt("com.apple"))
        XCTAssertTrue(ApplePackageFilter.isAppleReceipt("com.apple.pkg.Core"))
        XCTAssertFalse(ApplePackageFilter.isAppleReceipt("com.applesauce.pkg"), "must not match on the substring alone \u{2014} needs the dot")
    }
}
