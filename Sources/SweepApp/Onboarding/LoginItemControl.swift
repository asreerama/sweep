import ServiceManagement

/// "Launch Sweep at login" (onboarding step 3's login-item option). A thin wrapper around
/// `SMAppService.mainApp` — the same API `StartupItemsScreen`'s read-only "This App (SMAppService)"
/// row already reads (`SMAppServiceInventory.mainAppRow`), used here to actually register/
/// unregister rather than only display. No privileged helper involved: registering the main app
/// itself as a login item needs no elevated approval beyond the ordinary Login Items toggle
/// macOS already surfaces for any app that calls this.
enum LoginItemControl {
    static func isEnabled(service: SMAppService = .mainApp) -> Bool {
        service.status == .enabled
    }

    /// `.requiresApproval` (the user has to flip it on in System Settings > Login Items) counts
    /// as "on" for this toggle's purposes — the registration itself succeeded, it's an approval
    /// step, not a failure Sweep should surface as one.
    static func requiresApproval(service: SMAppService = .mainApp) -> Bool {
        service.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool, service: SMAppService = .mainApp) throws {
        if enabled {
            guard service.status != .enabled, service.status != .requiresApproval else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}
