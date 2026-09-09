import AppKit
import Foundation
import ServiceManagement

// MARK: - Where one item lives

/// Where one `StartupItemRow` was found. Login Items in the System-Settings sense (anything
/// registered via `SMAppService` by an app other than Sweep) have no public enumeration API —
/// PLAN §3 explicitly rules out the deprecated `LSSharedFileList` route — so this module's
/// inventory is exactly the three plist directories below, plus a best-effort read of Sweep's
/// own `SMAppService` registration (see `SMAppServiceInventory`). That gap is why the module also
/// ships the System Settings deep link.
enum StartupItemSource: String, CaseIterable, Sendable, Hashable {
    case userLaunchAgent
    case systemLaunchAgent
    case systemLaunchDaemon

    var title: String {
        switch self {
        case .userLaunchAgent: "Launch Agents (This User)"
        case .systemLaunchAgent: "Launch Agents (All Users)"
        case .systemLaunchDaemon: "Launch Daemons"
        }
    }

    var symbol: String {
        switch self {
        case .userLaunchAgent, .systemLaunchAgent: "gearshape"
        case .systemLaunchDaemon: "gearshape.2"
        }
    }

    /// Row-level chip text. The directory name is the developer's vocabulary; what a person
    /// actually needs from it is *who this runs for and with what power*, which is what these
    /// three phrases say.
    var scopeLabel: String {
        switch self {
        case .userLaunchAgent: "Only you"
        case .systemLaunchAgent: "Everyone"
        case .systemLaunchDaemon: "Root"
        }
    }

    var scopeSymbol: String {
        switch self {
        case .userLaunchAgent: "person"
        case .systemLaunchAgent: "person.2"
        case .systemLaunchDaemon: "shield.lefthalf.filled"
        }
    }

    /// Long form for the row tooltip — the chip is four characters, the explanation lives here.
    var scopeDetail: String {
        switch self {
        case .userLaunchAgent: "Runs when you log in, as you."
        case .systemLaunchAgent: "Runs for every account on this Mac, as whoever logs in."
        case .systemLaunchDaemon: "Runs as root, before anyone logs in."
        }
    }

    func directory(home: URL) -> URL {
        switch self {
        case .userLaunchAgent: home.appending(path: "Library/LaunchAgents")
        case .systemLaunchAgent: URL(fileURLWithPath: "/Library/LaunchAgents")
        case .systemLaunchDaemon: URL(fileURLWithPath: "/Library/LaunchDaemons")
        }
    }
}

// MARK: - When an item runs

/// What actually wakes an item up, read straight out of the launchd keys rather than inferred.
/// `RunAtLoad` alone was the module's only answer before, which made every one of a person's
/// background items look identical; "every hour" versus "at login" versus "only when something
/// asks for it" is the single most useful fact on the screen, so it is derived here and shown as
/// a chip on every row.
enum StartupItemTrigger: Hashable, Sendable {
    case alwaysOn
    case atLogin
    case everyInterval(seconds: Int)
    case onSchedule
    case onFileChange
    case onDemand

    var label: String {
        switch self {
        case .alwaysOn: "Always on"
        case .atLogin: "At login"
        case .everyInterval(let seconds): "Every \(Self.intervalPhrase(seconds))"
        case .onSchedule: "On a schedule"
        case .onFileChange: "On file change"
        case .onDemand: "On demand"
        }
    }

    var symbol: String {
        switch self {
        case .alwaysOn: "infinity"
        case .atLogin: "person.badge.key"
        case .everyInterval: "repeat"
        case .onSchedule: "calendar"
        case .onFileChange: "folder.badge.gearshape"
        case .onDemand: "moon.zzz"
        }
    }

    var detail: String {
        switch self {
        case .alwaysOn: "launchd restarts this whenever it stops, so it is meant to run continuously."
        case .atLogin: "Starts automatically as soon as you log in."
        case .everyInterval(let seconds): "Wakes up every \(Self.intervalPhrase(seconds)) and runs again."
        case .onSchedule: "Runs at fixed calendar times."
        case .onFileChange: "Sleeps until a folder it watches changes."
        case .onDemand: "Only starts when something explicitly asks for it — it is not costing you anything at login."
        }
    }

    /// "hour", "3 hours", "30 min" — the phrase that reads correctly after "Every".
    static func intervalPhrase(_ seconds: Int) -> String {
        guard seconds > 0 else { return "run" }
        if seconds < 60 { return seconds == 1 ? "second" : "\(seconds) seconds" }
        if seconds < 3600 {
            let minutes = seconds / 60
            return minutes == 1 ? "minute" : "\(minutes) min"
        }
        if seconds < 86_400 {
            let hours = seconds / 3600
            return hours == 1 ? "hour" : "\(hours) hours"
        }
        let days = seconds / 86_400
        return days == 1 ? "day" : "\(days) days"
    }
}

// MARK: - What an item is for

/// A plain-language bucket for what a background item is *doing there*, derived from its label
/// and the binary it runs. Deliberately coarse and deliberately guessed-from-name: there is no
/// API that reports a launchd job's purpose, so this is presented as a soft label beside the item
/// rather than as a fact the app acts on. Nothing in the module makes a decision from it.
enum StartupItemCategory: String, CaseIterable, Sendable, Hashable {
    case appleSystem
    case updater
    case sync
    case security
    case backup
    case developer
    case automation
    case helper

    var label: String {
        switch self {
        case .appleSystem: "Apple system"
        case .updater: "Updater"
        case .sync: "Cloud sync"
        case .security: "Security"
        case .backup: "Backup"
        case .developer: "Developer tool"
        case .automation: "Custom job"
        case .helper: "Background helper"
        }
    }

    var symbol: String {
        switch self {
        case .appleSystem: "apple.logo"
        case .updater: "arrow.triangle.2.circlepath"
        case .sync: "cloud"
        case .security: "lock.shield"
        case .backup: "externaldrive.badge.timemachine"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .automation: "terminal"
        case .helper: "gearshape"
        }
    }

    /// Keyword → category, checked in this order. First match wins, so the more specific
    /// vocabularies (updaters, backup) are listed before the generic ones.
    private static let keywordTable: [(keywords: [String], category: StartupItemCategory)] = [
        (["update", "keystone", "sparkle", "autoupdate", "upgrader", "installer", "ship it", "shipit"], .updater),
        (["backup", "backblaze", "timemachine", "time machine", "carbonite", "arq", "crashplan"], .backup),
        (["vpn", "antivirus", "malware", "firewall", "sophos", "mcafee", "norton", "avast", "littlesnitch",
          "little snitch", "1password", "onepassword", "authenticator", "yubi", "jamf", "zscaler",
          "endpoint", "security", "defender"], .security),
        (["sync", "onedrive", "dropbox", "gdrive", "googledrive", "google drive", "egnyte", "box",
          "nextcloud", "owncloud", "icloud", "mounter", "cloudstorage"], .sync),
        (["docker", "colima", "podman", "postgres", "mysql", "redis", "mongod", "ollama", "brew",
          "homebrew", "node", "nvm", "jenkins", "gitlab", "runner", "xcode", "simulator"], .developer),
    ]

    static func classify(label: String, executablePath: String?, isScriptJob: Bool) -> StartupItemCategory {
        if label.hasPrefix("com.apple.") { return .appleSystem }
        let haystack = ([label, executablePath ?? ""].joined(separator: " ")).lowercased()
        for entry in keywordTable where entry.keywords.contains(where: { haystack.contains($0) }) {
            return entry.category
        }
        return isScriptJob ? .automation : .helper
    }
}

// MARK: - One parsed item

/// One parsed launchd plist. `id` is the plist's own path, which doubles as the reveal target.
struct StartupItemRow: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let programPath: String?
    let arguments: [String]
    let source: StartupItemSource
    let runAtLoad: Bool
    let binaryExists: Bool
    let trigger: StartupItemTrigger
    let category: StartupItemCategory
    /// `AssociatedBundleIdentifiers` — the launchd key an app uses to say "this job is mine".
    /// The strongest attribution signal available, and the reason a Zoom updater can show Zoom's
    /// icon without any guessing at all.
    let associatedBundleIDs: [String]
    let isDisabledInPlist: Bool
    /// The path the job actually executes: the script a shell was handed where `Program` is an
    /// interpreter, otherwise the program itself. Attribution and the category keywords both read
    /// this rather than `programPath`, or every shell-driven job would be attributed to `/bin/zsh`.
    let executablePath: String?

    /// A label with no program that actually exists on disk: the item will fail to launch.
    /// `programPath == nil` (a plist with neither `Program` nor `ProgramArguments`) is not itself
    /// flagged broken — that shape is unusual but not invalid, and this module has no way to
    /// know what launchd would have done with it.
    var isBroken: Bool { programPath != nil && !binaryExists }

    var isApple: Bool { label.hasPrefix("com.apple.") }

    /// Starts on its own without anybody asking — the set a person means by "what runs at startup".
    var startsByItself: Bool {
        switch trigger {
        case .alwaysOn, .atLogin, .everyInterval, .onSchedule: true
        case .onFileChange, .onDemand: false
        }
    }

    /// The reverse-DNS label with its vendor prefix stripped and the remainder title-cased:
    /// `com.google.keystone.agent` → "Keystone Agent". Lossy on purpose — the exact label is
    /// still shown underneath in mono, so this line is free to be the readable one.
    var displayName: String { StartupItemAttribution.friendlyName(fromLabel: label) }
}

// MARK: - Parsing

/// Parses one launchd-style plist into a row. Pure: the disk check is an injected closure so this
/// is testable without touching the filesystem, and the default matches what
/// `StartupItemsScanner` uses for a real scan.
enum StartupItemParser {
    static func parse(
        plistData: Data,
        path: String,
        source: StartupItemSource,
        fallbackLabel: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> StartupItemRow? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        else { return nil }

        // A plist with no `Label` is not unparseable in the real world: launchd falls back to the
        // filename, and at least one shipping vendor (Google Keystone) actually ships an empty
        // agent plist. The fallback is opt-in from the caller rather than derived from `path`
        // here, so a caller that has no filename to trust still gets `nil`.
        guard let label = (plist["Label"] as? String) ?? fallbackLabel else { return nil }

        let program = plist["Program"] as? String
        let arguments = (plist["ProgramArguments"] as? [String]) ?? []
        let programPath = program ?? arguments.first
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        let exists = programPath.map(fileExists) ?? false
        let executablePath = StartupItemAttribution.executablePath(programPath: programPath, arguments: arguments)
        let isScriptJob = programPath.map(StartupItemAttribution.isInterpreter) ?? false

        return StartupItemRow(
            id: path,
            label: label,
            programPath: programPath,
            arguments: arguments,
            source: source,
            runAtLoad: runAtLoad,
            binaryExists: exists,
            trigger: trigger(from: plist, runAtLoad: runAtLoad),
            category: StartupItemCategory.classify(label: label, executablePath: executablePath, isScriptJob: isScriptJob),
            associatedBundleIDs: (plist["AssociatedBundleIdentifiers"] as? [String])
                ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] }
                ?? [],
            isDisabledInPlist: (plist["Disabled"] as? Bool) ?? false,
            executablePath: executablePath
        )
    }

    /// Precedence is by what the person would say first about the job, not by launchd's own key
    /// ordering: "it never stops" beats "it starts at login" beats "it wakes up hourly".
    static func trigger(from plist: [String: Any], runAtLoad: Bool) -> StartupItemTrigger {
        // `KeepAlive` is documented as either a Bool or a dictionary of conditions; both mean
        // launchd is responsible for restarting the job, which is the fact the chip reports.
        if (plist["KeepAlive"] as? Bool) == true || plist["KeepAlive"] is [String: Any] { return .alwaysOn }
        if runAtLoad { return .atLogin }
        if let interval = plist["StartInterval"] as? Int, interval > 0 { return .everyInterval(seconds: interval) }
        if plist["StartCalendarInterval"] != nil { return .onSchedule }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil { return .onFileChange }
        return .onDemand
    }
}

/// Read-only directory listing over the three launchd plist roots. Every failure (unreadable
/// directory, unparsable plist) is dropped silently rather than surfaced: a system-owned
/// `/Library/LaunchDaemons` entry this process cannot read is routine, not an error worth a
/// footnote the way a scan's skipped roots are.
enum StartupItemsScanner {
    static func scanDirectory(
        _ url: URL,
        source: StartupItemSource,
        fileManager: FileManager = .default
    ) -> [StartupItemRow] {
        guard let entries = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "plist" }
            .compactMap { fileURL -> StartupItemRow? in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return StartupItemParser.parse(
                    plistData: data,
                    path: fileURL.path,
                    source: source,
                    fallbackLabel: fileURL.deletingPathExtension().lastPathComponent
                )
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func scanAll(home: URL, fileManager: FileManager = .default) -> [StartupItemRow] {
        StartupItemSource.allCases.flatMap { source in
            scanDirectory(source.directory(home: home), source: source, fileManager: fileManager)
        }
    }
}

// MARK: - Live state (launchctl)

/// One line of `launchctl list`: whether the job has a process right now, and how it exited last
/// time. Both are read-only facts launchd already publishes to an unprivileged caller.
struct LaunchdStatus: Hashable, Sendable {
    let pid: Int32?
    let lastExitStatus: Int32
}

/// Parses `launchctl list`'s three tab-separated columns (`PID`, `Status`, `Label`). Split out
/// pure so the interesting cases — the `-` placeholders, negative exit statuses, the header —
/// are testable without spawning anything.
enum LaunchctlListParser {
    static func parse(_ output: String) -> [String: LaunchdStatus] {
        var result: [String: LaunchdStatus] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 3 else { continue }
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label != "Label" else { continue }
            result[label] = LaunchdStatus(
                pid: Int32(columns[0].trimmingCharacters(in: .whitespaces)),
                lastExitStatus: Int32(columns[1].trimmingCharacters(in: .whitespaces)) ?? 0
            )
        }
        return result
    }
}

/// `launchctl list` for the calling user's GUI domain. Read-only, no `sudo`, no shell — the same
/// bounded-pipe runner Maintenance uses for `dscacheutil`.
///
/// Scope is deliberately not papered over: this returns the *user* domain only, so a
/// `/Library/LaunchDaemons` job is simply absent from the result rather than reported as "not
/// loaded". `StartupItemRunState.resolve` turns that absence into `.unknown` for daemons, which
/// is why the UI shows no state chip for them instead of a wrong one.
enum LaunchdStatusService {
    static func snapshot() -> [String: LaunchdStatus] {
        guard let output = try? LocalProcessRunner.run("/bin/launchctl", ["list"], timeout: 8) else { return [:] }
        return LaunchctlListParser.parse(output)
    }
}

/// What the item is doing right now, as far as this process can honestly tell.
enum StartupItemRunState: Hashable, Sendable {
    case running(pid: Int32)
    case loaded
    case failed(code: Int32)
    case notLoaded
    case disabled
    case unknown

    static func resolve(row: StartupItemRow, status: LaunchdStatus?) -> StartupItemRunState {
        if row.isDisabledInPlist { return .disabled }
        guard let status else {
            // Absence proves nothing for a root daemon — this process can only see its own
            // domain — so it reports nothing rather than "not loaded".
            return row.source == .systemLaunchDaemon ? .unknown : .notLoaded
        }
        if let pid = status.pid { return .running(pid: pid) }
        if status.lastExitStatus != 0 { return .failed(code: status.lastExitStatus) }
        return .loaded
    }

    var label: String? {
        switch self {
        case .running: "Running"
        case .loaded: "Loaded"
        case .failed(let code): "Failed (\(code))"
        case .notLoaded: "Not loaded"
        case .disabled: "Disabled"
        case .unknown: nil
        }
    }

    var detail: String? {
        switch self {
        case .running(let pid): "Running right now as process \(pid)."
        case .loaded: "launchd has this loaded and it exited cleanly last time."
        case .failed(let code): "The last run exited with status \(code). It may be failing every time it starts."
        case .notLoaded: "The file is here but launchd has not loaded it in your session."
        case .disabled: "Turned off in its own configuration; launchd will not start it."
        case .unknown: nil
        }
    }

    var isAttention: Bool { if case .failed = self { true } else { false } }
    var isRunning: Bool { if case .running = self { true } else { false } }
}

// MARK: - Attribution (which app put this here)

/// Turns a launchd job into "who this belongs to". Everything here is pure string/path work; the
/// LaunchServices and icon lookups it feeds live in `StartupOwnerResolver` so this stays testable.
enum StartupItemAttribution {
    /// Programs that are only ever a vehicle for the real job. A plist whose `Program` is one of
    /// these is attributed by its first argument instead, or every shell-driven job on the Mac
    /// would be grouped under `/bin/zsh`.
    static let interpreters: Set<String> = [
        "/bin/sh", "/bin/bash", "/bin/zsh", "/bin/ksh", "/bin/csh", "/bin/tcsh",
        "/usr/bin/env", "/usr/bin/python", "/usr/bin/python3", "/usr/bin/perl", "/usr/bin/ruby",
        "/usr/bin/osascript", "/usr/bin/open", "/usr/local/bin/node", "/opt/homebrew/bin/node",
        "/usr/local/bin/python3", "/opt/homebrew/bin/python3",
    ]

    static func isInterpreter(_ path: String) -> Bool { interpreters.contains(path) }

    /// The path the job really runs. For an interpreter, the first argument that looks like a
    /// path rather than a flag; otherwise the program itself.
    static func executablePath(programPath: String?, arguments: [String]) -> String? {
        guard let programPath else { return nil }
        guard isInterpreter(programPath) else { return programPath }
        let candidate = arguments.dropFirst().first { $0.hasPrefix("/") }
        return candidate ?? programPath
    }

    /// The *outermost* `.app` a path sits inside: `…/zoom.us.app/Contents/Library/LaunchAgents/
    /// ZoomUpdater.app/…` attributes to zoom.us, not to the nested updater helper. Same choice
    /// `MemoryScreen` makes for process attribution, and for the same reason — a person thinks in
    /// terms of the app they installed, not the helper bundle buried in it.
    static func outermostAppBundlePath(for path: String) -> String? {
        var prefix: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            prefix.append(String(component))
            if component.hasSuffix(".app") { return prefix.joined(separator: "/") }
        }
        return nil
    }

    /// Reverse-DNS TLD-ish first components, so `us.zoom.updater` yields "zoom" rather than "us".
    private static let reverseDNSPrefixes: Set<String> = [
        "com", "org", "net", "io", "us", "co", "de", "uk", "dev", "app", "ai", "me", "fr", "ca",
        "cloud", "xyz", "tv", "fm", "sh", "gg", "eu", "info", "biz", "edu", "gov", "at", "ch",
        "nl", "se", "no", "jp", "cn", "in", "au", "ru", "it", "es", "pl", "cz",
    ]

    /// The vendor token inside a reverse-DNS label: `com.google.keystone.agent` → "google".
    static func vendorToken(fromLabel label: String) -> String? {
        let parts = label.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        if reverseDNSPrefixes.contains(parts[0].lowercased()) { return parts[1].lowercased() }
        return parts[0].lowercased()
    }

    /// Names people actually recognize, for the vendors whose reverse-DNS token is not simply
    /// their name capitalized. Anything not listed falls back to capitalizing the token, which is
    /// right far more often than it is wrong.
    private static let vendorNames: [String: String] = [
        "google": "Google", "microsoft": "Microsoft", "zoom": "Zoom", "adobe": "Adobe",
        "dropbox": "Dropbox", "docker": "Docker", "apple": "Apple", "egnyte": "Egnyte",
        "nordvpn": "NordVPN", "tailscale": "Tailscale", "logitech": "Logitech",
        "spotify": "Spotify", "slack": "Slack", "citrix": "Citrix", "vmware": "VMware",
        "parallels": "Parallels", "backblaze": "Backblaze", "malwarebytes": "Malwarebytes",
        "agilebits": "1Password", "onepassword": "1Password", "objective-see": "Objective-See",
        "obdev": "Objective Development", "crashplan": "CrashPlan", "teamviewer": "TeamViewer",
        "jamf": "Jamf", "sophos": "Sophos", "mcafee": "McAfee", "avast": "Avast",
        "brave": "Brave", "mozilla": "Mozilla", "github": "GitHub", "jetbrains": "JetBrains",
        "elgato": "Elgato", "razer": "Razer", "valvesoftware": "Steam", "steampowered": "Steam",
        "epicgames": "Epic Games", "discord": "Discord", "whatsapp": "WhatsApp",
        "telegram": "Telegram", "notion": "Notion", "figma": "Figma", "grammarly": "Grammarly",
        "zscaler": "Zscaler", "cloudflare": "Cloudflare", "homebrew": "Homebrew",
        "ollama": "Ollama", "openvpn": "OpenVPN", "wireguard": "WireGuard", "oracle": "Oracle",
    ]

    static func vendorDisplayName(forToken token: String) -> String {
        if let known = vendorNames[token] { return known }
        return token.prefix(1).uppercased() + token.dropFirst()
    }

    /// Progressive reverse-DNS prefixes of a label, longest first:
    /// `com.google.keystone.agent` → `com.google.keystone`, `com.google`.
    static func bundleIDPrefixes(forLabel label: String) -> [String] {
        let parts = label.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return [] }
        return (2..<parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }
    }

    /// Words that carry no information on their own, so a label ending in one keeps the component
    /// before it: `com.google.keystone.agent` reads "Keystone Agent", not "Agent".
    private static let genericTailWords: Set<String> = [
        "agent", "daemon", "helper", "service", "xpcservice", "app", "plist", "login", "check",
    ]

    private static let acronymSpellings: [String: String] = [
        "xpcservice": "XPC Service", "xpc": "XPC", "ui": "UI", "vpn": "VPN", "ssd": "SSD",
        "cli": "CLI", "api": "API", "os": "OS", "db": "DB", "fs": "FS", "dns": "DNS",
    ]

    static func friendlyName(fromLabel label: String) -> String {
        var parts = label.split(separator: ".").map(String.init)
        // Drop the vendor prefix — the group header already says whose this is.
        if parts.count >= 3, reverseDNSPrefixes.contains(parts[0].lowercased()) {
            parts.removeFirst(2)
        } else if parts.count >= 2, !reverseDNSPrefixes.contains(parts[0].lowercased()) {
            parts.removeFirst()
        }
        guard !parts.isEmpty else { return label }
        // Keep the last two components when the final one is a filler word.
        if parts.count > 2, genericTailWords.contains(parts[parts.count - 1].lowercased()) {
            parts = Array(parts.suffix(2))
        }
        let words = parts
            .flatMap { $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init) }
            .map { word -> String in
                // Acronyms title-casing would mangle into something that reads like a typo.
                if let fixed = acronymSpellings[word.lowercased()] { return fixed }
                // Already-capitalized vendor spellings (OneDriveStandaloneUpdater, EgnyteFS) are
                // left exactly as shipped; only all-lowercase components get title-cased.
                return word.first?.isLowercase == true ? word.prefix(1).uppercased() + word.dropFirst() : word
            }
        return words.isEmpty ? label : words.joined(separator: " ")
    }
}

// MARK: - Owner (the group a row is filed under)

/// Who a set of background items belongs to. This is the screen's organizing principle: a person
/// scanning the list asks "what put this here", and the answer is an app they recognize far more
/// often than it is a directory on disk.
struct StartupOwner: Identifiable, Hashable, Sendable {
    enum Kind: Int, Hashable, Sendable {
        case app       // resolved to an installed .app — real icon, real name
        case vendor    // a company we can name but no single app to point at
        case scripts   // a script or job someone set up by hand on this Mac
        case apple     // com.apple.* — system machinery, not a person's choice
        case other
    }

    let id: String
    let name: String
    let kind: Kind
    /// Path to the `.app` whose icon represents this owner, when one was resolved.
    let appPath: String?
    /// Fallback glyph when there is no icon.
    let symbol: String
    let subtitle: String?

    /// Apple's own machinery sorts last and is filtered out of the "third-party" count — it is
    /// not something a person installed or can meaningfully act on from here.
    var isApple: Bool { kind == .apple }
}

/// Shallow index of installed apps, bundle identifier → bundle URL. Built once per load on a
/// background task; used to answer "is there an app that owns `com.google.keystone.agent`" without
/// LaunchServices round-trips per row.
struct InstalledAppIndex: Sendable {
    /// Exact bundle identifier → app path.
    let byBundleID: [String: String]
    /// Lowercased bundle identifier → app path, for case-insensitive prefix work.
    private let sortedIDs: [String]

    static let searchRoots: [String] = [
        "/Applications",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
    ]

    init(byBundleID: [String: String]) {
        self.byBundleID = byBundleID
        self.sortedIDs = byBundleID.keys.sorted()
    }

    static func build(roots: [String] = searchRoots) -> InstalledAppIndex {
        var map: [String: String] = [:]
        let fileManager = FileManager.default
        for root in roots {
            guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = root + "/" + name
                // `Bundle(path:)` reads Info.plist lazily and is cheap enough for the ~100 app
                // bundles a Mac typically has; a full `NSMetadataQuery` would be heavier and needs
                // Spotlight to be enabled, which cannot be assumed.
                guard let id = Bundle(path: path)?.bundleIdentifier, map[id] == nil else { continue }
                map[id] = path
            }
        }
        return InstalledAppIndex(byBundleID: map)
    }

    func path(forBundleID id: String) -> String? { byBundleID[id] }

    /// Every installed app whose identifier sits under `prefix` (`com.google` matches
    /// `com.google.Chrome`). Used to decide between "one obvious owning app" and "this vendor
    /// ships several, name the vendor instead".
    func paths(underPrefix prefix: String) -> [String] {
        let needle = prefix.lowercased() + "."
        return sortedIDs.compactMap { id in
            id.lowercased().hasPrefix(needle) ? byBundleID[id] : nil
        }
    }
}

/// Resolves each row to an owner, in descending order of how much the signal can be trusted.
enum StartupOwnerResolver {
    static func displayName(forAppAt path: String) -> String {
        let bundle = Bundle(path: path)
        let info = bundle?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        return name ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    static func appOwner(path: String) -> StartupOwner {
        StartupOwner(
            id: "app:" + path,
            name: displayName(forAppAt: path),
            kind: .app,
            appPath: path,
            symbol: "app.badge",
            subtitle: nil
        )
    }

    static func owner(for row: StartupItemRow, index: InstalledAppIndex) -> StartupOwner {
        // 1. The app declared the job as its own. Nothing beats being told.
        for id in row.associatedBundleIDs {
            if let path = index.path(forBundleID: id) { return appOwner(path: path) }
        }
        // 2. The binary lives inside an app bundle.
        if let executablePath = row.executablePath,
           let appPath = StartupItemAttribution.outermostAppBundlePath(for: executablePath) {
            return appOwner(path: appPath)
        }
        // 3. The label *is* an installed app's bundle identifier, or a child of one.
        for prefix in StartupItemAttribution.bundleIDPrefixes(forLabel: row.label) {
            if let path = index.path(forBundleID: prefix) { return appOwner(path: path) }
        }
        if row.isApple {
            return StartupOwner(
                id: "apple",
                name: "macOS",
                kind: .apple,
                appPath: nil,
                symbol: "apple.logo",
                subtitle: "Apple system services"
            )
        }
        // 4. One installed app sits under the vendor prefix — attribute to it. Several, and the
        //    honest answer is the vendor's name rather than an arbitrary pick among them.
        if let vendorPrefix = StartupItemAttribution.bundleIDPrefixes(forLabel: row.label).last {
            let matches = index.paths(underPrefix: vendorPrefix)
            if matches.count == 1, let path = matches.first { return appOwner(path: path) }
        }
        if let token = StartupItemAttribution.vendorToken(fromLabel: row.label) {
            let isScript = row.programPath.map(StartupItemAttribution.isInterpreter) ?? false
            // A hand-written script under a personal reverse-DNS label is nobody's product; it is
            // something set up on this Mac, and filing it under a made-up "vendor" would be a lie.
            if isScript, index.paths(underPrefix: token).isEmpty, index.path(forBundleID: token) == nil {
                return StartupOwner(
                    id: "scripts",
                    name: "Scripts & custom jobs",
                    kind: .scripts,
                    appPath: nil,
                    symbol: "terminal",
                    subtitle: "Set up on this Mac, not by an installed app"
                )
            }
            return StartupOwner(
                id: "vendor:" + token,
                name: StartupItemAttribution.vendorDisplayName(forToken: token),
                kind: .vendor,
                appPath: nil,
                symbol: "shippingbox",
                subtitle: "No matching app found on this Mac"
            )
        }
        return StartupOwner(
            id: "other",
            name: "Unattributed",
            kind: .other,
            appPath: nil,
            symbol: "questionmark.app.dashed",
            subtitle: "Sweep could not tell which app installed these"
        )
    }
}

/// One owner and its items, as rendered.
struct StartupOwnerGroup: Identifiable, Hashable, Sendable {
    let owner: StartupOwner
    let rows: [StartupItemRow]
    var id: String { owner.id }
}

// MARK: - SMAppService (this app's own registration)

/// One `SMAppService`-visible entry: Sweep's own login/agent/daemon registration, read where the
/// public API actually exposes it (PLAN §3: "SMAppService-visible items where readable"). There
/// is no public call that lists *other* apps' registrations, which is the whole reason this
/// module also ships a System Settings deep link rather than pretending to be complete.
struct SMAppServiceRow: Identifiable, Hashable {
    let id: String
    let label: String
    let statusDescription: String
}

enum SMAppServiceInventory {
    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval"
        case .notFound: "Not found"
        @unknown default: "Unknown"
        }
    }

    /// Sweep's own launch-at-login registration, if any. Reflects reality even before Sweep ever
    /// registers one: `SMAppService.mainApp.status` is `.notRegistered` until it does.
    static func mainAppRow(bundle: Bundle = .main) -> SMAppServiceRow {
        let name = (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleExecutable"] as? String)
            ?? "Sweep"
        return SMAppServiceRow(
            id: "main-app",
            label: "\(name) (launch at login)",
            statusDescription: describe(SMAppService.mainApp.status)
        )
    }

    /// Helper agents/daemons bundled under `Contents/Library/{LaunchAgents,LaunchDaemons}` — per
    /// PLAN Appendix B, the only place a plist may live for `SMAppService` to see it. Sweep ships
    /// no helper yet (that lands at P4), so this is normally empty; the mechanism exists so a row
    /// appears the moment one does, with no UI change needed then.
    static func bundledServiceRows(bundle: Bundle = .main) -> [SMAppServiceRow] {
        let subdirectories: [(path: String, isDaemon: Bool)] = [
            ("Contents/Library/LaunchAgents", false),
            ("Contents/Library/LaunchDaemons", true),
        ]
        var rows: [SMAppServiceRow] = []
        for entry in subdirectories {
            let directory = bundle.bundleURL.appending(path: entry.path)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let service = entry.isDaemon ? SMAppService.daemon(plistName: name) : SMAppService.agent(plistName: name)
                rows.append(SMAppServiceRow(id: name, label: name, statusDescription: describe(service.status)))
            }
        }
        return rows
    }

    static func allRows(bundle: Bundle = .main) -> [SMAppServiceRow] {
        [mainAppRow(bundle: bundle)] + bundledServiceRows(bundle: bundle)
    }
}
