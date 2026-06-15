    /// Warm-serve freshness sweep — refresh ONLY the repos already
    /// hydrated in this resident process. Sibling to
    /// `refresh_repositories_from_heki`, with two deliberate
    /// differences that make it the right primitive for `serve` mode :
    ///
    ///   1. **No env gate.** `serve` calls this unconditionally before
    ///      every dispatch. The `HECKS_REFRESH_REPOS=1` guard on the
    ///      sibling exists to keep one-shot CLI dispatches and in-memory
    ///      smoke tests from re-reading mid-cascade ; a resident server
    ///      that answers from a warm runtime must ALWAYS reconcile with
    ///      disk first, because daemons (heart/breath) write `.heki`
    ///      concurrently between requests.
    ///
    ///   2. **Hydrated-only.** `LazyRepository::refresh_from_heki` forces
    ///      `repo_mut()` → `get_or_init` → hydration. Sweeping ALL repos
    ///      would hydrate every aggregate on the first request and throw
    ///      away the lazy-boot win this whole feature is built on. We
    ///      filter on `is_hydrated()` : a repo that's never been touched
    ///      stays cold (and, when it IS first touched by a later
    ///      dispatch, the OnceCell init reads current disk by
    ///      definition — so cold repos are fresh for free). Only the
    ///      handful of repos this process has actually served pay the
    ///      one `stat()` per request ; the mtime gate inside
    ///      `refresh_from_heki` skips the re-read when disk is unchanged.
    ///
    /// This is THE correctness crux of warm serve : the IR stays warm
    /// (the boot is paid once) but the touched aggregate's STATE is
    /// never stale.
    pub fn refresh_hydrated_repositories_from_heki(&mut self) {
        for repo in self.repositories.values_mut() {
            if repo.is_hydrated() {
                repo.refresh_from_heki();
            }
        }
    }
