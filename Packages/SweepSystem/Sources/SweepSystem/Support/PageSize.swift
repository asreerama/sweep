import Darwin

/// The kernel's VM page size, in bytes.
///
/// Every page-count field returned by `host_statistics64` must be multiplied by this value to
/// get bytes (PLAN.md Appendix B / §3).
///
/// The natural API for this is the extern global `vm_kernel_page_size`, but Swift 6 strict
/// concurrency flags any read of it ("not concurrency-safe because it involves shared mutable
/// state") since it is an unannotated mutable C global. `host_page_size(mach_host_self(), _:)`
/// reports the identical value (the kernel sets both from the same page-size at boot and never
/// changes it for the lifetime of the process) through a plain function call, which passes
/// strict concurrency checking cleanly. This function is the small audited wrapper around that
/// one `Darwin` call.
enum SystemPageSize {
    /// Cached after the first successful read: the page size cannot change while the process is
    /// alive, so re-querying the kernel on every sample would be pure overhead.
    static let bytes: UInt64 = {
        var pageSize: vm_size_t = 0
        let result = host_page_size(mach_host_self(), &pageSize)
        guard result == KERN_SUCCESS, pageSize > 0 else {
            // Every Apple Silicon and Intel Mac in the support window uses a 16 KiB or 4 KiB
            // page; 4096 is the conservative fallback if the host call ever fails.
            return 4096
        }
        return UInt64(pageSize)
    }()
}
