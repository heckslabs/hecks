    /// File mtime for our heki path, when the file exists. Used by
    /// load / save / refresh to track whether the in-memory store is
    /// current with disk. Returns None when data_dir is unset, the
    /// file doesn't exist yet, or the stat call fails — all of which
    /// the freshness logic treats as "no recorded mtime, fall through
    /// to a read."
    fn current_disk_mtime(&self) -> Option<SystemTime> {
        let dir = self.data_dir.as_ref()?;
        let path = self.heki_path_self(dir);
        std::fs::metadata(&path).and_then(|m| m.modified()).ok()
    }

    /// Re-read the heki file when disk mtime has advanced past our
    /// last_seen_mtime — i.e. another process wrote since our last
    /// load or save. No-op when disk is unchanged (just a stat call).
    /// Honors the `RefreshIfStale` command declared on the Repository
    /// aggregate in runtime/storage/storage.bluebook ; the
    /// `RefreshOnPulse` policy on BodyPulse fans this out across every
    /// repo via Runtime::refresh_repositories_from_heki on each tick.
    pub fn refresh_from_heki(&mut self) {
        let Some(disk_mtime) = self.current_disk_mtime() else { return };
        let stale = match self.last_seen_mtime {
            Some(seen) => disk_mtime > seen,
            None => true,
        };
        if !stale { return; }
        // Drop in-memory store and reload from disk. Counter-mint
        // state (next_id) is rebuilt by load_persisted's max-id walk.
        self.store.clear();
        self.next_id = 1;
        self.load_persisted();
    }
