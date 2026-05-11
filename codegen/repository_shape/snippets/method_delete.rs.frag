    /// Remove a record from the in-memory store and persist the
    /// updated set back to heki. The companion to `save` for the
    /// `then_delete` mutation primitive ; only retire-style commands
    /// reach this path.
    ///
    /// Snapshots the heki file before deleting so the prior store can
    /// be recovered if the deletion was wrong. Snapshot failure is
    /// logged but does not block the delete — the dispatch path must
    /// stay live even if the snapshots dir is unwritable.
    pub fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) {
        self.store.remove(id);
        if let Some(ref dir) = self.data_dir {
            // Context-aware path resolution (i142 Tier 2) — picks the
            // namespaced or flat heki path per the aggregate's
            // declared context.
            let path = self.heki_path_self(dir);
            // Snapshot before delete (i122 round 1, the heki snapshot
            // primitive) — the only destructive runtime call gets a
            // backup. Failures log but don't block the dispatch.
            match heki::snapshot(&path) {
                Ok(Some(snap)) => {
                    if std::env::var("HECKS_HEKI_AUDIT").ok().as_deref() == Some("1") {
                        eprintln!("[heki:snapshot] {} → {}", path, snap);
                    }
                }
                Ok(None) => {} // file didn't exist — nothing to snapshot
                Err(e) => eprintln!("[heki:snapshot] warning: {}", e),
            }
            let _ = heki::delete(&path, id, ctx);
            // Same freshness-bookkeeping as save : stamp the post-write
            // mtime so refresh_from_heki skips re-reading our own
            // delete on the next tick.
            self.last_seen_mtime = self.current_disk_mtime();
        }
    }
