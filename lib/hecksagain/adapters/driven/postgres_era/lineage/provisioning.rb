module Hecksagain
  module Adapters
    class PostgresEra
      class Lineage
        module Provisioning
          # Provisioning is the OWNER's job, and a deployment's app role is
          # deliberately not the owner — it may append and read, and it
          # owns nothing. By the time such a role connects, the base is
          # already built, so its boot verifies rather than builds.
          #
          # Without this guard the per-era fence below is unreachable: the
          # ALTER TABLE and REVOKE here are owner-only, so the very role
          # grant_era! exists to constrain could never finish booting
          # ("must be owner of table hecks_eras"). A fence nothing can
          # reach is not a fence.
          def ensure_base!
            rename_domain! if @formerly_known_as
            return unless provisioner?

            @db.exec(<<~SQL)
              CREATE TABLE IF NOT EXISTS hecks_eras (
                domain    text NOT NULL,
                ordinal   int  NOT NULL,
                hash      text,
                label     text,
                held_text text NOT NULL,
                watermark bigint,
                PRIMARY KEY (domain, ordinal)
              )
            SQL
            @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_digest text")
            @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS held_projection jsonb")
            # which canonical-form version minted this name — see
            # Runtime::StorageShape::FORM_VERSION; rows minted before the
            # column carry NULL, read as an implicit 1
            @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS canon_form int")
            # every frozen text version, archived where an edit cannot
            # reach it — the recovery the hard reattest refusal points at
            @db.exec(<<~SQL)
              CREATE TABLE IF NOT EXISTS hecks_era_texts (
                domain      text NOT NULL,
                ordinal     int  NOT NULL,
                digest      text NOT NULL,
                held_text   text NOT NULL,
                archived_at timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (domain, ordinal, digest)
              )
            SQL
            @db.exec(<<~SQL)
              CREATE TABLE IF NOT EXISTS hecks_approvals (
                domain           text NOT NULL,
                from_label       text NOT NULL,
                to_label         text NOT NULL,
                edge_digest      text NOT NULL,
                reviewed_ordinal bigint NOT NULL,
                approved_at      timestamptz NOT NULL DEFAULT now()
              )
            SQL
            @db.exec("CREATE SEQUENCE IF NOT EXISTS #{quote(sequence)}")
            # GENERATED ALWAYS AS IDENTITY is the intent, but identity
            # columns on partitioned tables need Postgres 17 — an owned
            # sequence default is the same spanning ordinal on any
            # supported server.
            @db.exec(<<~SQL)
              CREATE TABLE IF NOT EXISTS #{quoted_journal} (
                ordinal      bigint NOT NULL DEFAULT nextval('#{sequence}'),
                era          int    NOT NULL,
                aggregate    text   NOT NULL,
                aggregate_id text   NOT NULL,
                operation    text   NOT NULL DEFAULT 'save',
                state        jsonb,
                mirrors      jsonb
              ) PARTITION BY LIST (era)
            SQL
            ensure_partition!(1)
            # Immutability by privilege: nothing updates or deletes journal
            # rows. The owner's implicit rights remain (Postgres has no way
            # to revoke them from the owner itself); a deployment's app
            # role connects as a NON-owner and gets exactly INSERT, per
            # era, at mint time.
            @db.exec("REVOKE UPDATE, DELETE ON #{quoted_journal} FROM PUBLIC")
            # RLS goes on AT PROVISIONING, never mid-life — enabling it
            # later would deny every role that has no policy yet, on
            # whatever the shape of the schema happened to be at that
            # moment.
            #
            # FORCE, not merely ENABLE: without it, the table OWNER is
            # exempt from every policy here, by Postgres default — which
            # would leave the schema writable forever to whoever holds
            # the owner's credentials, the one connection this whole
            # design cannot fence. Checked, not assumed: mint_era! never
            # inserts into the journal at all (only hecks_eras/
            # hecks_era_texts, neither RLS-protected), and merge_tail!'s
            # one journal INSERT targets the CURRENT era, which the fence
            # already admits for anyone with base privileges — so FORCE
            # costs the owner nothing operations here actually need.
            #
            # This still exempts an actual Postgres SUPERUSER (or any
            # role granted BYPASSRLS) unconditionally — FORCE only
            # narrows what ENABLE already narrows for the owner
            # specifically, and superuser bypass sits above both. Running
            # migrations as a real superuser (self-hosted Postgres, most
            # commonly) leaves this gap open regardless; a managed
            # provider's admin account is typically NOT a superuser, and
            # is exactly what FORCE closes.
            #
            # GUARDED, not reissued unconditionally — measured, not
            # assumed: `ALTER TABLE ... ENABLE/FORCE ROW LEVEL SECURITY`
            # takes AccessExclusiveLock EVEN WHEN THE SETTING IS ALREADY
            # CORRECT (Postgres does not skip the lock just because the
            # statement would be a no-op). ensure_base! runs on EVERY
            # boot by the owning role, not only the first — so an
            # unconditional reissue here would mean every ordinary
            # reboot of the deployment's own identity re-freezes every
            # concurrent writer, on any era, for as long as that ALTER
            # TABLE has to wait its turn. Read the current state first;
            # touch the catalog only on the boot that actually needs to.
            # pg_table_is_visible, NOT a bare relname match — a shared
            # instance (storehouse) can hold a same-named journal table
            # per schema; catalog lookups here must resolve the SAME way
            # search_path resolves an unqualified SQL reference, or a
            # sibling domain's table satisfies a query meant for this
            # domain's own.
            current = @db.exec_params(
              "SELECT relrowsecurity, relforcerowsecurity FROM pg_class " \
              "WHERE relname = $1 AND pg_table_is_visible(oid)", [journal]
            )[0]
            @db.exec("ALTER TABLE #{quoted_journal} ENABLE ROW LEVEL SECURITY") unless current["relrowsecurity"] == "t"
            @db.exec("ALTER TABLE #{quoted_journal} FORCE ROW LEVEL SECURITY") unless current["relforcerowsecurity"] == "t"
            install_transforms!
          end

          # A DOMAIN'S OWN IDENTITY CHANGED — bridge its history under the
          # new name, before `provisioner?`/the CREATE TABLE IF NOT EXISTS
          # block below ever run. That ordering is load-bearing, not
          # tidiness: `provisioner?` and every statement in ensure_base!
          # test for the journal under `journal` — the NEW name — and a
          # freshly-renamed domain looks, to those checks, exactly like a
          # domain that has never been provisioned at all. Left where it
          # was written, ensure_base! would happily CREATE TABLE IF NOT
          # EXISTS a brand-new, empty journal under the new name before
          # this method ever got a chance to run — and the ALTER TABLE ...
          # RENAME below would then fail, renaming onto a name that
          # already exists.
          #
          # Three-way precheck, cheapest first:
          #   1. no hecks_eras table at all yet — a genuinely fresh
          #      database; nothing to bridge, fall through to the
          #      ordinary provisioning path.
          #   2. hecks_eras already has rows under the NEW name — this
          #      rename already ran (a prior boot, possibly this one on a
          #      retry); idempotent no-op.
          #   3. hecks_eras has rows under the OLD name — run the
          #      migration.
          # Anything else (no rows under either name) falls through
          # harmlessly — `formerly_known_as` pointing at a name with no
          # held history is not an error, just inert.
          def rename_domain!
            return unless @db.exec_params("SELECT to_regclass($1)", ["hecks_eras"])[0]["to_regclass"]
            return if @db.exec_params(
              "SELECT 1 FROM hecks_eras WHERE domain = $1 LIMIT 1", [@domain]
            ).ntuples.positive?
            return if @db.exec_params(
              "SELECT 1 FROM hecks_eras WHERE domain = $1 LIMIT 1", [@formerly_known_as]
            ).ntuples.zero?

            old_journal  = "hecks_journal_#{Naming.snake(@formerly_known_as)}"
            old_sequence = "#{old_journal}_ordinal"
            ordinals = @db.exec_params(
              "SELECT ordinal FROM hecks_eras WHERE domain = $1 ORDER BY ordinal", [@formerly_known_as]
            ).map { |row| row["ordinal"].to_i }

            @db.exec("BEGIN")
            @db.exec("SET LOCAL lock_timeout = '10s'")
            # Fixed order — old before new, the `eras:` family before the
            # `ordinal:` family — so two rename attempts (or a rename
            # racing a mint/plain-write on either name) can only ever
            # queue behind one another, never deadlock.
            [
              "hecks_eras:#{@formerly_known_as}", "hecks_eras:#{@domain}",
              "hecks_ordinal:#{@formerly_known_as}", "hecks_ordinal:#{@domain}"
            ].each do |key|
              @db.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
            end

            @db.exec("ALTER TABLE #{quote(old_journal)} RENAME TO #{quote(journal)}")
            # An owned SERIAL/IDENTITY sequence moves automatically with
            # its table and errors if renamed explicitly — this one is a
            # plain CREATE SEQUENCE the journal's DEFAULT merely points
            # at (see ensure_base!), so it does need its own rename, and
            # the column default survives untouched: Postgres stores
            # nextval('...') as a regclass reference internally, not
            # literal text.
            @db.exec("ALTER SEQUENCE #{quote(old_sequence)} RENAME TO #{quote(sequence)}")
            # ALTER TABLE ... RENAME on the parent does NOT cascade to
            # child partition names — each one needs its own explicit
            # rename, sourced from the ordinals held under the OLD name,
            # captured above before the UPDATE below flips the column.
            ordinals.each do |ordinal|
              old_partition = "#{old_journal}_era_#{ordinal}"
              @db.exec("ALTER TABLE #{quote(old_partition)} RENAME TO #{quote(partition(ordinal))}")
            end

            %w[hecks_eras hecks_era_texts hecks_approvals].each do |table|
              @db.exec_params("UPDATE #{table} SET domain = $1 WHERE domain = $2", [@domain, @formerly_known_as])
            end
            # Unlike its siblings, hecks_attestations is not created in
            # ensure_base! at all — only lazily, on first reattest! — so a
            # domain that never needed one must not be forced through an
            # UPDATE against a table that doesn't exist.
            if @db.exec_params("SELECT to_regclass($1)", ["hecks_attestations"])[0]["to_regclass"]
              @db.exec_params("UPDATE hecks_attestations SET domain = $1 WHERE domain = $2", [@domain, @formerly_known_as])
            end

            @db.exec("COMMIT")
          rescue PG::LockNotAvailable
            @db.exec("ROLLBACK") rescue nil
            raise Runtime::WiringError,
                  "cannot rename #{@formerly_known_as} to #{@domain}: another rename, mint, or write holds " \
                  "one of the domain locks — waited 10s; try again shortly"
          rescue PG::Error => error
            @db.exec("ROLLBACK") rescue nil
            raise Runtime::WiringError, "cannot rename #{@formerly_known_as} to #{@domain}: #{error.message.strip}"
          end

          # Nothing provisioned yet — build it. Provisioned and owned —
          # keep it current. Provisioned by SOMEONE ELSE — this is an app
          # role, and the owner has already done this work.
          def provisioner?
            rows = @db.exec_params(
              "SELECT pg_get_userbyid(relowner) = current_user AS owned FROM pg_class " \
              "WHERE relname = $1 AND pg_table_is_visible(oid)",
              [journal]
            )
            rows.ntuples.zero? || rows[0]["owned"] == "t"
          end

          # BUILD, THEN ATTACH — never CREATE ... PARTITION OF. The two
          # produce the same partition; only the lock differs, and that
          # difference is the whole availability story of a mint:
          #
          #   CREATE TABLE ... PARTITION OF  → AccessExclusiveLock (parent)
          #   CREATE, then ALTER ... ATTACH  → ShareUpdateExclusiveLock
          #
          # AccessExclusive conflicts with every insert in the hierarchy —
          # routed through the parent OR addressed to an existing leaf —
          # so attaching the new era inside the mint transaction stopped
          # every writer for the WHOLE mint, tail materialization
          # included. ShareUpdateExclusive conflicts with neither, so the
          # old checkout keeps writing its own era straight through the
          # build and only pauses for the head swap at the end.
          #
          # That is what makes the fork real DURING a mint rather than
          # merely before and after one. Measured, and pinned by the spec
          # — which writes through a live mint rather than reading a lock
          # mode out of the catalog.
          def ensure_partition!(era)
            return if partition_attached?(era)

            @db.exec(<<~SQL)
              CREATE TABLE IF NOT EXISTS #{quote(partition(era))} (
                LIKE #{quoted_journal} INCLUDING DEFAULTS
              )
            SQL
            @db.exec(<<~SQL)
              ALTER TABLE #{quoted_journal}
                ATTACH PARTITION #{quote(partition(era))} FOR VALUES IN (#{era.to_i})
            SQL
          end

          # Attached, not merely present: a crash between the CREATE and
          # the ATTACH leaves a table that is not yet part of the journal,
          # and the next boot must finish the job rather than skip it.
          def partition_attached?(era)
            @db.exec_params(
              "SELECT 1 FROM pg_inherits i " \
              "JOIN pg_class child ON child.oid = i.inhrelid " \
              "JOIN pg_class parent ON parent.oid = i.inhparent " \
              "WHERE child.relname = $1 AND parent.relname = $2 " \
              "AND pg_table_is_visible(child.oid) AND pg_table_is_visible(parent.oid)",
              [partition(era), journal]
            ).ntuples.positive?
          end
        end
      end
    end
  end
end
