    /// Rebuild on the SQL backend ONLY those aggregates whose governing
    /// hecksagon declares `:sqlite` — matched by `agg.context ==
    /// hecksagon.name`. A hecksagon is a bluebook's companion file ; its
    /// name is the bluebook name, which the parser stamps as every
    /// aggregate's `context`. Typed columns derive from the bluebook IR
    /// (one column per scalar attribute, types via `sqlite_mapping::
    /// sql_type`) ; the db path is that hecksagon's `db:` option. Every
    /// other aggregate keeps the heki/memory repository
    /// `boot_with_data_dir` built. A no-op when no `:sqlite` hecksagon is
    /// attached.
    ///
    /// i735 — previously this OVER-APPLIED : any one `:sqlite` hecksagon
    /// rebuilt EVERY aggregate in a combined multi-domain root on SQL,
    /// panicking the whole bus when an unrelated aggregate carried
    /// SQL-incompatible columns. Scoping by context confines `:sqlite` to
    /// its own declaring domain, so it is safe to declare anywhere.
    #[cfg(not(target_arch = "wasm32"))]
    pub(super) fn apply_sqlite_persistence(&mut self) {
        // context → db_path for every hecksagon that wired :sqlite.
        let sqlite_dbs: HashMap<String, String> = self
            .hecksagons
            .iter()
            .filter(|hex| hex.persistence.as_deref() == Some("sqlite"))
            .filter_map(|hex| {
                // parse_options keeps the raw token (quotes included) ;
                // strip the surrounding quotes to get the bare path.
                hex.persistence_option("db")
                    .map(|db| (hex.name.clone(), db.trim_matches('"').to_string()))
            })
            .collect();
        if sqlite_dbs.is_empty() {
            return;
        }
        // Collect patches under the immutable borrow of self.domain, then
        // apply them under the mutable borrow of self.repositories — the
        // two borrows cannot overlap through &mut self.
        let patches: Vec<(String, lazy_repository::SqliteConfig)> = self
            .domain
            .aggregates
            .iter()
            .filter_map(|agg| {
                let db_path = agg.context.as_deref().and_then(|ctx| sqlite_dbs.get(ctx))?;
                let mut columns: Vec<(String, String)> = agg
                    .attributes
                    .iter()
                    // Exclude the auto-managed columns `create_table` always
                    // adds itself : `id TEXT PRIMARY KEY`, `created_at`,
                    // `updated_at`. Every aggregate carries an `id` attribute
                    // (its identity) ; including it here produced a "duplicate
                    // column name: id" CREATE TABLE failure — latent under the
                    // old lazy path, surfaced now that construction is eager.
                    .filter(|a| {
                        !a.list
                            && !matches!(a.name.as_str(), "id" | "created_at" | "updated_at")
                    })
                    .map(|a| (a.name.clone(), sqlite_mapping::sql_type(&a.attr_type).to_string()))
                    .collect();
                // The lifecycle state field (e.g. `status`) is set on the
                // AggregateState at dispatch but is not a declared
                // attribute ; the typed-columns backend needs a TEXT
                // column for it or a cold query filtering on it reads
                // back nothing.
                if let Some(lc) = &agg.lifecycle {
                    columns.push((lc.field.clone(), "TEXT".to_string()));
                }
                let key = repo_key(agg.context.as_deref(), &agg.name);
                Some((
                    key,
                    lazy_repository::SqliteConfig {
                        aggregate_type: agg.name.clone(),
                        db_path: db_path.clone(),
                        identified_by: agg.identified_by.clone(),
                        columns,
                    },
                ))
            })
            .collect();
        for (key, config) in patches {
            // EAGER construction (i735 defect 2) : open + CREATE TABLE +
            // row-load happen now, at boot, because they are FALLIBLE.
            match sqlite_repository::SqliteRepository::new(
                &config.aggregate_type,
                &config.db_path,
                config.identified_by.clone(),
                config.columns.clone(),
            ) {
                Ok(repo) => {
                    self.repositories
                        .insert(key, LazyRepository::new_sqlite(repo));
                }
                Err(e) => {
                    // Never panic the bus ; never silently fall back to heki.
                    // Refuse THIS aggregate LOUDLY : drop its repository so no
                    // heki repo survives to be silently swapped in, and record
                    // the reason. The boot log names it now ; a dispatch
                    // against it returns a loud PersistenceRefused error.
                    let reason = format!(
                        "{key} : sqlite persistence refused — open/CREATE TABLE failed for db `{}`: {e}",
                        config.db_path
                    );
                    eprintln!("[persistence] {reason}");
                    self.repositories.remove(&key);
                    self.refused_persistence.insert(key, reason);
                }
            }
        }
    }
