require_relative "../../../../../../runtime/registry"
require_relative "../../storage_shape"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # `mint_era!`: writes a new era in one transaction and advances the current-era
        # RLS fence (`advance_era!`) just before commit.
        module MintTransaction
          # The era a mint writes: its name, frozen text, the aggregates to recompile and the
          # edge chain that derives their heads.
          Mint = Data.define(:ordinal, :shape_hash, :label, :held_text, :aggregates, :edges, :role, :projection) do
            def initialize(role: nil, projection: nil, **rest) = super
          end

          # Makes a new era real in one locked transaction, or reports a concurrent minter won.
          #
          # @param hash [String] the era's shape hash, SHA-256 hex
          # @param fields [Hash] the keywords of `Mint`: `ordinal:` (one past the newest held era),
          #   `label:` (a prefix of `hash`),
          #   `held_text:` (the bluebook source to freeze as this era), `aggregates:` (whose heads
          #   are recompiled), `edges:` (the full edge chain in mint order, one per step), and
          #   optionally `role:` (app role to grant privileges to; nil grants nothing) and
          #   `projection:` (the storage-shape projection, or nil)
          # @return [Boolean] true once committed; false, rolled back, if `ordinal` is held
          # @raise [Runtime::WiringError] on a lock wait over 10s or a Postgres error
          # @raise [ArgumentError] on a missing or unknown keyword
          def mint_era!(hash:, **fields)
            mint = Mint.new(shape_hash: hash, **fields)
            return false if stand_down?(mint)

            write_era!(mint)
            true
          rescue PG::LockNotAvailable
            rollback_quietly
            raise Runtime::WiringError, lock_refusal(mint)
          rescue PG::Error => e
            rollback_quietly
            raise Runtime::WiringError, "cannot mint era #{mint.ordinal} of #{@domain}: #{e.message.strip}"
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

            aggregates.each { |aggregate| grant_head!(aggregate.storage_name, era, quoted_role) }
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

          private

          # Opens the mint transaction and takes the domain's mint lock. When a concurrent minter
          # already holds this ordinal, rolls back and answers true.
          def stand_down?(mint)
            @db.exec("BEGIN")
            # Mint is non-interactive, so a concurrent minter fails fast with a name, not a hang.
            @db.exec("SET LOCAL lock_timeout = '10s'")
            @db.exec("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:' || #{text_literal(@domain)}))")
            held = eras.any? { |era| era[:ordinal] == mint.ordinal }
            @db.exec("ROLLBACK") if held
            held
          end

          def write_era!(mint)
            insert_era!(mint)
            materialize_era!(mint)
            @db.exec("COMMIT")
          end

          def lock_refusal(mint)
            "cannot mint era #{mint.ordinal} of #{@domain}: another mint holds the domain lock — " \
              "waited 10s; try again shortly"
          end

          def insert_era!(mint)
            @db.exec_params(
              "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, " \
              "held_projection, canon_form) " \
              "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
              [@domain, mint.ordinal, mint.shape_hash, mint.label, mint.held_text, last_ordinal,
               Digest::SHA256.hexdigest(mint.held_text), mint.projection && JSON.generate(mint.projection),
               Runtime::StorageShape::FORM_VERSION]
            )
          end

          def materialize_era!(mint)
            archive_text!(mint.ordinal, mint.held_text)
            ensure_partition!(mint.ordinal)
            compile_and_grant!(mint)
            # Must stay last, right before `COMMIT`: DROP/CREATE POLICY takes an
            # AccessExclusiveLock held to commit, so placing it before compile_head!
            # would block every writer for the whole matview build.
            #
            # Unconditional, even with no role configured: the cutoff is a fact about the
            # era, and a role granted by an earlier boot must lose old-era writes on commit.
            advance_era!(mint.ordinal)
          end

          # grant_role! must follow compile_head!, which creates the per-era snapshot
          # tables that it grants on.
          def compile_and_grant!(mint)
            mint.aggregates.each { |aggregate| compile_head!(aggregate, mint.ordinal, mint.label, mint.edges) }
            grant_role!(mint.role, aggregates: mint.aggregates, era: mint.ordinal) if mint.role
          end

          def grant_head!(storage_name, era, quoted_role)
            @db.exec("GRANT SELECT, INSERT, UPDATE, DELETE ON #{quote(head_snapshot(storage_name, era))} TO #{quoted_role}")
            return unless view_exists?(head_view(storage_name))

            @db.exec("GRANT SELECT ON #{quote(head_view(storage_name))} TO #{quoted_role}")
          end
        end
      end
    end
  end
end
