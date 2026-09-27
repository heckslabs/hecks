require_relative "../../../../../../runtime/registry"
require_relative "../../storage_shape"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # `mint_era!`: writes a new era in one transaction and advances the current-era
        # RLS fence (`advance_era!`) just before commit.
        module MintTransaction
          # Makes a new era real in one locked transaction, or reports a concurrent minter won.
          #
          # @param ordinal [Integer] ordinal of the era to mint, one past the newest held era
          # @param hash [String] the era's shape hash, SHA-256 hex
          # @param label [String] the era's short label, a prefix of `hash`
          # @param held_text [String] the bluebook source text to freeze as this era
          # @param aggregates [Array<Bluebook::Aggregate>] aggregates whose heads are recompiled
          # @param edges [Array<Hash>] the full edge chain in mint order, one per step
          # @param role [String, nil] app role to grant privileges to; nil grants nothing
          # @param projection [Hash{String => Object}, nil] storage-shape projection, or nil
          # @return [Boolean] true once committed; false, rolled back, if `ordinal` is held
          # @raise [Runtime::WiringError] on a lock wait over 10s or a Postgres error
          def mint_era!(ordinal:, hash:, label:, held_text:, aggregates:, edges:, role: nil, projection: nil)
            @db.exec("BEGIN")
            # Mint is non-interactive, so a concurrent minter fails fast with a name, not a hang.
            @db.exec("SET LOCAL lock_timeout = '10s'")
            @db.exec("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:' || #{text_literal(@domain)}))")
            if eras.any? { |era| era[:ordinal] == ordinal }
              @db.exec("ROLLBACK")
              return false
            end

            watermark = last_ordinal
            @db.exec_params(
              "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, " \
              "held_projection, canon_form) " \
              "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
              [@domain, ordinal, hash, label, held_text, watermark, Digest::SHA256.hexdigest(held_text),
               projection && JSON.generate(projection), Runtime::StorageShape::FORM_VERSION]
            )
            archive_text!(ordinal, held_text)
            ensure_partition!(ordinal)
            # grant_role! must follow compile_head!, which creates the per-era snapshot
            # tables that it grants on.
            aggregates.each { |aggregate| compile_head!(aggregate, ordinal, label, edges) }
            grant_role!(role, aggregates: aggregates, era: ordinal) if role
            # Must stay last, right before `COMMIT`: DROP/CREATE POLICY takes an
            # AccessExclusiveLock held to commit, so placing it before compile_head!
            # would block every writer for the whole matview build.
            #
            # Unconditional, even with no role configured: the cutoff is a fact about the
            # era, and a role granted by an earlier boot must lose old-era writes on commit.
            advance_era!(ordinal)
            @db.exec("COMMIT")
            true
          rescue PG::LockNotAvailable
            begin
              @db.exec("ROLLBACK")
            rescue StandardError
              nil
            end
            raise Runtime::WiringError,
                  "cannot mint era #{ordinal} of #{@domain}: another mint holds the domain lock — " \
                  "waited 10s; try again shortly"
          rescue PG::Error => e
            begin
              @db.exec("ROLLBACK")
            rescue StandardError
              nil
            end
            raise Runtime::WiringError, "cannot mint era #{ordinal} of #{@domain}: #{e.message.strip}"
          end

          # Grants an app role what it needs to append to the journal and read and write heads.
          #
          # Idempotent and owner-only, so a non-owner boot skips it. Head snapshot tables are
          # era-scoped, so `era:` names the ordinal the role is about to write under.
          #
          # @param role [String] name of the Postgres role to grant to
          # @param aggregates [Array<Bluebook::Aggregate>] aggregates whose head tables and views
          #   are granted on; ignored when `era` is nil
          # @param era [Integer, nil] era whose snapshot tables to grant on; nil grants only the
          #   journal and sequence privileges
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a grant
          def grant_role!(role, aggregates: [], era: nil)
            return unless provisioner?

            quoted_role = quote(role)
            @db.exec("GRANT INSERT, SELECT ON #{quoted_journal} TO #{quoted_role}")
            @db.exec("GRANT USAGE ON SEQUENCE #{quote(sequence)} TO #{quoted_role}")
            return unless era

            aggregates.each do |aggregate|
              storage_name = aggregate.storage_name
              @db.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON #{quote(head_snapshot(storage_name, era))} TO #{quoted_role}")
              if view_exists?(head_view(storage_name))
                @db.exec("GRANT SELECT ON #{quote(head_view(storage_name))} " \
                         "TO #{quoted_role}")
              end
            end
          end

          # Replaces the journal's row policies: one era accepts INSERTs, every row stays readable.
          #
          # One policy shared by every role; call only with the new current ordinal, since a
          # superseded one would roll the fence back. The table owner bypasses RLS.
          #
          # Row policy rather than partition grants: Postgres checks INSERT privilege on the
          # partitioned parent and ignores the partition's own grants.
          #
          # @param ordinal [Integer] ordinal of the era that becomes the only writable one
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the policy change, such as for a non-owner
          def advance_era!(ordinal)
            @db.exec("DROP POLICY IF EXISTS hecks_current_era ON #{quoted_journal}")
            @db.exec(
              "CREATE POLICY hecks_current_era ON #{quoted_journal} FOR INSERT TO PUBLIC " \
              "WITH CHECK (era = #{ordinal.to_i})"
            )
            @db.exec("DROP POLICY IF EXISTS hecks_read_all ON #{quoted_journal}")
            @db.exec("CREATE POLICY hecks_read_all ON #{quoted_journal} FOR SELECT TO PUBLIC USING (true)")
          end
        end
      end
    end
  end
end
