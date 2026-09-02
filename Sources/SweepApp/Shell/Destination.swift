import Foundation
import SweepUI

/// Sidebar destinations, in the order PLAN §3 fixes them.
///
/// The two-tier split is data, not layout: `tier` decides which half of the sidebar a
/// destination lives in and how loudly it is drawn. Toolbox entries are advanced, user-driven
/// and never auto-select anything, and the sidebar says so before the user clicks.
enum Destination: String, Hashable, Identifiable, CaseIterable {
    case smartScan
    case systemJunk
    case largeFiles
    case memory
    case maintenance
    case startupItems
    case uninstaller
    case developer
    case homebrew
    case appLipo
    case plugins
    case packages
    case fileSearch
    case listStress
    case cleanFlowPreview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: "Smart Scan"
        case .systemJunk: "System Junk"
        case .largeFiles: "Large & Old Files"
        case .memory: "Memory"
        case .maintenance: "Maintenance"
        case .startupItems: "Startup Items"
        case .uninstaller: "Uninstaller"
        case .developer: "Developer"
        case .homebrew: "Homebrew"
        case .appLipo: "App Lipo"
        case .plugins: "Plugins"
        case .packages: "Packages"
        case .fileSearch: "File Search"
        case .listStress: "List Stress"
        case .cleanFlowPreview: "Clean Flow Preview"
        }
    }

    /// Glyph set v2 (user-directed: "think about modern icons for the same things" — the
    /// literal-object symbols read as a boomer utility): each module keeps its meaning but
    /// speaks the current SaaS register — cleaning is bubbles-and-sparkles rather than a trash
    /// can, maintenance is tuning sliders rather than a wrench, uninstalling is the dashed app
    /// frame rather than an x-marked bin, developer is code brackets rather than a hammer.
    var symbol: String {
        switch self {
        case .smartScan: "sparkles"
        case .systemJunk: "bubbles.and.sparkles"
        case .largeFiles: "archivebox"
        case .memory: "memorychip"
        case .maintenance: "slider.horizontal.3"
        case .startupItems: "bolt"
        case .uninstaller: "app.dashed"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .homebrew: "mug"
        case .appLipo: "scissors"
        case .plugins: "puzzlepiece.extension"
        case .packages: "cube"
        case .fileSearch: "text.magnifyingglass"
        case .listStress: "speedometer"
        case .cleanFlowPreview: "sparkle.magnifyingglass"
        }
    }

    var tier: SidebarTier {
        switch self {
        case .developer, .homebrew, .appLipo, .plugins, .packages, .fileSearch, .listStress, .cleanFlowPreview: .toolbox
        default: .primary
        }
    }

    /// One line, shown under the screen title. Says what the module does and what it will not do.
    var subtitle: String {
        switch self {
        case .smartScan: "One pass over caches, logs and developer junk. Cleaning moves items to the Trash."
        case .systemJunk: "Everything the rule catalog claims, grouped by rule."
        case .largeFiles: "Volume scan with size and age filters."
        case .memory: "Live pressure, compressor stats and the apps holding the memory."
        case .maintenance: "DNS flush, Spotlight reindex, APFS snapshot thinning."
        case .startupItems: "Login items and background services, with reveal and deep links."
        case .uninstaller: "Full app removal with auditable ownership evidence per leftover."
        case .developer: "Per-environment caches with live sizes. Nothing is ever auto-selected."
        case .homebrew: "Formulae, casks, outdated packages and cache, previewed before anything runs."
        case .appLipo: "Trim Intel-only code from universal apps. Apple-signed apps are never touched."
        case .plugins: "Spotlight importers, Quick Look, audio units and app extensions \u{2014} and what installed them."
        case .packages: "Installer receipts recorded by macOS \u{2014} what got installed, when, and where. Read-only."
        case .fileSearch: "Find any file by name, sorted by what it costs you."
        case .listStress: "Debug harness: 10,000 synthetic rows through the shipping inventory list."
        case .cleanFlowPreview: "Debug harness: confirm / progress / report states, ahead of the Gate 1 flip."
        }
    }
}

/// One labelled block of the sidebar.
struct SidebarGroup: Identifiable {
    let id: String
    let title: String?
    let destinations: [Destination]

    /// Primary tier, top of the sidebar, in plan order.
    static let primary: [SidebarGroup] = [
        SidebarGroup(id: "hero", title: nil, destinations: [.smartScan]),
        SidebarGroup(id: "clean", title: "Clean", destinations: [.systemJunk, .largeFiles]),
        SidebarGroup(id: "speed", title: "Speed", destinations: [.memory, .maintenance, .startupItems]),
        SidebarGroup(id: "apps", title: "Apps", destinations: [.uninstaller]),
    ]

    /// Toolbox tier, pinned to the bottom, quieter. The stress harness and the Clean flow preview
    /// only appear when `SWEEP_UI_STRESS` is set, so neither ships in a normal run.
    static func toolbox(includingStressHarness: Bool) -> SidebarGroup {
        SidebarGroup(
            id: "toolbox",
            title: "Toolbox",
            destinations: [.developer, .homebrew, .appLipo, .plugins, .packages, .fileSearch]
                + (includingStressHarness ? [.listStress, .cleanFlowPreview] : [])
        )
    }
}
