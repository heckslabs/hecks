module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # Owner-only schema bootstrap: lineage tables, the RLS fence, the domain rename
        # bridge, and per-era journal partitions.
        module Provisioning
          # Builds or tops up this domain's lineage schema when the connected role owns the
          # journal (or none exists yet); any other role only attempts the rename bridge.
          #
          # ALTER TABLE and REVOKE are owner-only, so a non-owner app role must skip them to boot.
          #
          # @return [void]
          # @raise [Runtime::WiringError] if the `formerly_known_as` rename cannot take
          #   its locks within 10s or Postgres refuses one of its statements
          # @raise [PG::Error] if Postgres refuses a provisioning statement
          # rubocop:disable-next Metrics/MethodLength
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
            # Canonical-form version that minted the name (Runtime::StorageShape::FORM_VERSION);
            # NULL reads as 1.
            @db.exec("ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS canon_form int")
            # Every frozen text version, archived where an edit cannot reach it.
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
            # An owned sequence default, not GENERATED ALWAYS AS IDENTITY, which
            # partitioned tables only support from Postgres 17.
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
            # Journal rows are immutable by privilege: nothing updates or deletes them.
            # The REVOKE is guarded because it rewrites pg_class.relacl and takes a lock
            # even when nothing changes, so concurrent reboots would race into
            # `tuple concurrently updated`.
            #
            # The guard is `relacl IS NULL`, not has_table_privilege('public', ..., 'UPDATE'):
            # a new table already answers "no UPDATE", so that check would skip the first
            # REVOKE and leave relacl NULL forever. pg_table_is_visible(oid), not a bare
            # relname match, so a sibling schema's same-named table is never mistaken for ours.
            relacl_null = @db.exec_params(
              "SELECT relacl IS NULL FROM pg_class WHERE relname = $1 AND pg_table_is_visible(oid)", [journal]
            ).getvalue(0, 0)
            @db.exec("REVOKE UPDATE, DELETE ON #{quoted_journal} FROM PUBLIC") if relacl_null == "t"
            # RLS goes on at provisioning, never mid-life: enabling it later would deny
            # every role that has no policy yet.
            #
            # FORCE, not just ENABLE, or the table owner is exempt from every policy. A
            # superuser or BYPASSRLS role stays exempt regardless (see check_fence_applies!).
            #
            # Guarded: ENABLE/FORCE takes an AccessExclusiveLock even as a no-op, and this
            # runs on every boot, so an unconditional reissue would freeze concurrent writers.
            current = @db.exec_params(
              "SELECT relrowsecurity, relforcerowsecurity FROM pg_class " \
              "WHERE relname = $1 AND pg_table_is_visible(oid)", [journal]
            )[0]
            @db.exec("ALTER TABLE #{quoted_journal} ENABLE ROW LEVEL SECURITY") unless current["relrowsecurity"] == "t"
            @db.exec("ALTER TABLE #{quoted_journal} FORCE ROW LEVEL SECURITY") unless current["relforcerowsecurity"] == "t"
            install_transforms!
          end

          # Moves a domain's journal, sequence, partitions and lineage rows from
          # `formerly_known_as` to the current name, in one transaction.
          #
          # Runs before `provisioner?` and the CREATE TABLE calls in `ensure_base!`; a no-op when
          # `hecks_eras` is missing, the new name has rows, or the former name has none.
          # Locks go in a fixed order (old before new, eras before ordinal) so nothing deadlocks.
          #
          # @return [void]
          # @raise [Runtime::WiringError] if the locks are not granted within 10s or Postgres
          #   refuses a statement (prechecks included); both roll back first
          # rubocop:disable-next Metrics/AbcSize
          # rubocop:disable-next Metrics/MethodLength
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
            [
              "hecks_eras:#{@formerly_known_as}", "hecks_eras:#{@domain}",
              "hecks_ordinal:#{@formerly_known_as}", "hecks_ordinal:#{@domain}"
            ].each do |key|
              @db.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
            end

            @db.exec("ALTER TABLE #{quote(old_journal)} RENAME TO #{quote(journal)}")
            # The sequence is a plain CREATE SEQUENCE, not owned by the column, so it
            # does not move with the table and needs its own rename.
            @db.exec("ALTER SEQUENCE #{quote(old_sequence)} RENAME TO #{quote(sequence)}")
            # Renaming the parent does not rename its partitions.
            ordinals.each do |ordinal|
              old_partition = "#{old_journal}_era_#{ordinal}"
              @db.exec("ALTER TABLE #{quote(old_partition)} RENAME TO #{quote(partition(ordinal))}")
            end

            %w[hecks_eras hecks_era_texts hecks_approvals].each do |table|
              @db.exec_params("UPDATE #{table} SET domain = $1 WHERE domain = $2", [@domain, @formerly_known_as])
            end
            # hecks_attestations is created lazily on first reattest!, so it may not exist.
            if @db.exec_params(
              "SELECT to_regclass($1)", ["hecks_attestations"]
            )[0]["to_regclass"]
              @db.exec_params("UPDATE hecks_attestations SET domain = $1 WHERE domain = $2",
                              [@domain, @formerly_known_as])
            end

            @db.exec("COMMIT")
          rescue PG::LockNotAvailable
            begin
              @db.exec("ROLLBACK")
            rescue StandardError
              nil
            end
            raise Runtime::WiringError,
                  "cannot rename #{@formerly_known_as} to #{@domain}: another rename, mint, or write holds " \
                  "one of the domain locks — waited 10s; try again shortly"
          rescue PG::Error => e
            begin
              @db.exec("ROLLBACK")
            rescue StandardError
              nil
            end
            raise Runtime::WiringError, "cannot rename #{@formerly_known_as} to #{@domain}: #{e.message.strip}"
          end

          # Refuses to boot on a connection whose role Postgres exempts from row-level security
          # (a superuser or BYPASSRLS role) unless the caller opts in.
          #
          # Those roles bypass the write-fence, so a stale checkout could keep writing a
          # superseded era unnoticed. With `allow_superuser` it boots and warns on stderr.
          #
          # @param allow_superuser [Boolean, Object, nil] any truthy value boots anyway
          #   with a warning on stderr; `false` or `nil` refuses
          # @return [nil] when the role is fenced, or after the warning is written
          # @raise [Runtime::WiringError] if the connection's role is a superuser or is
          #   granted BYPASSRLS, and `allow_superuser` is not truthy
          # @raise [PG::Error] if the `pg_roles` lookup fails
          def check_fence_applies!(allow_superuser: false)
            row = @db.exec("SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")[0]
            exempt = []
            exempt << "a superuser" if row["rolsuper"] == "t"
            exempt << "granted BYPASSRLS" if row["rolbypassrls"] == "t"
            return if exempt.empty?

            role = row["rolname"].inspect
            unless allow_superuser
              raise Runtime::WiringError,
                    "cannot boot #{@domain}: PostgresEra's era write-fence is row-level security, and this " \
                    "connection's role #{role} is #{exempt.join(' and ')} — Postgres exempts it from every " \
                    "policy, FORCE included, so an old checkout connected this way keeps writing a superseded " \
                    "era and nothing refuses. Connect as an ordinary role instead (database " \
                    "\"postgres://<role>@<host>/<db>\" in the .world — a non-superuser OWNER still provisions " \
                    "and mints), or declare `allow_superuser true` in the same persisted_by block to boot with " \
                    "the fence void, on the record."
            end

            warn "[hecks] #{@domain}: booting PostgresEra as #{role}, #{exempt.join(' and ')}, under " \
                 "allow_superuser — the era write-fence is void for this connection; only this process's own " \
                 "superseded-era check (PostgresEra#append) stands between an old checkout and a superseded era"
          end

          # Tells whether this connection's role is the one that builds the schema:
          # it owns the domain's journal, or no journal is visible yet.
          #
          # @return [Boolean] true when no journal table is visible on the search path
          #   or `current_user` owns it; false when another role owns it
          # @raise [PG::Error] if the catalog lookup fails
          def provisioner?
            rows = @db.exec_params(
              "SELECT pg_get_userbyid(relowner) = current_user AS owned FROM pg_class " \
              "WHERE relname = $1 AND pg_table_is_visible(oid)",
              [journal]
            )
            rows.ntuples.zero? || rows[0]["owned"] == "t"
          end

          # Creates and attaches one era's journal partition, unless it is already
          # attached; finishes the attach for a table a crashed boot left detached.
          #
          # Build then ATTACH, never CREATE ... PARTITION OF: the latter takes an
          # AccessExclusiveLock on the parent and stops every writer for the whole mint,
          # while ATTACH takes only ShareUpdateExclusiveLock, so a running checkout keeps
          # writing through the build.
          #
          # @param era [Integer] ordinal of the era whose partition is ensured
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the create or the attach
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

          # Tells whether an era's partition is part of the journal, by asking
          # `pg_inherits` rather than checking that the table exists.
          #
          # A table left by a crash between CREATE and ATTACH exists but is not attached,
          # and the next boot must finish the job.
          #
          # @param era [Integer] ordinal of the era whose partition is looked up
          # @return [Boolean] true when the partition is attached to this domain's
          #   journal; false when it is missing or exists unattached
          # @raise [PG::Error] if the catalog lookup fails
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
