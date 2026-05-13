    /// i557 part 1 — boot with hecksagons AND a framework directory so
    /// the registry can discover adapter families + behavior kinds at
    /// boot. The framework dir is typically
    /// `<aggregates_dir>/framework` (e.g.
    /// `hecks_conception/aggregates/framework`). Falls back to the
    /// kernel-hook-only registry if the dir doesn't exist — safe for
    /// callers that don't ship a framework conception.
    ///
    /// `Runtime::dispatch` itself doesn't consult the registry yet
    /// (part 2 retires the hardcoded `:claude_tool` path) ; this
    /// constructor just lands the substrate.
    pub fn boot_with_framework_dir(
        domain: Domain,
        data_dir: Option<String>,
        hecksagons: Vec<Hecksagon>,
        framework_dir: &std::path::Path,
    ) -> Self {
        let mut rt = Self::boot_with_data_dir(domain, data_dir);
        rt.hecksagons = hecksagons;
        rt.framework_registry =
            framework_registry::FrameworkRegistry::build_from_dir(framework_dir);
        rt
    }

