require_relative "../../../../../../runtime/registry"
require_relative "../../storage_shape"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # `mint_era!` itself: one transaction that writes the new era row,
        # attaches its partition, recompiles every aggregate's head, grants
        # an app role, and — last, right before commit — advances the
        # current-era RLS fence (`advance_era!`) that drops write access to
        # the old schema the instant it commits.
        module MintTransaction
          # ── the mint transaction ───────────────────────────────────────
          #
          # Makes a new era real, or reports that a concurrent minter already did.
          #
          # One transaction: the new era row (held text + minted name +
          # cut watermark), the new partition, and every aggregate's
          # recompiled matview + head view. The advisory lock is the
          # writer fence — two concurrent minters serialize, and the
          # second finds the era already held. Populating the matview
          # inside the transaction means a convert meeting an unmapped
          # value refuses the whole mint, loudly, before anything boots.
          #
          # @param ordinal [Integer] ordinal of the era to mint, one past the newest held era
          # @param hash [String] the new era's shape hash, SHA-256 hex
          # @param label [String] the new era's short label, a prefix of `hash`
          # @param held_text [String] the bluebook source text to freeze as this era
          # @param aggregates [Array<Bluebook::Aggregate>] the current bluebook's aggregates, each
          #   of which gets its head recompiled
          # @param edges [Array<Hash{Symbol => Bluebook::Translation}>] the full edge chain in mint
          #   order, one `{ translation: }` Hash per step, as `LineageManager.edge_chain` builds it
          # @param role [String, nil] app role to grant base and head privileges to; nil grants
          #   nothing
          # @param projection [Hash{String => Object}, nil] the bluebook's storage-shape
          #   projection, as `Runtime::StorageShape.project` returns it; nil stores none
          # @return [Boolean] true once the era is committed; false, with everything rolled back,
          #   when the domain already holds `ordinal`
          # @raise [Runtime::WiringError] if another mint or merge holds the domain lock for over
          #   10s, if Postgres refuses any statement (a convert meeting an unmapped value
          #   included), or if a held era's text fails its integrity check
          def mint_era!(ordinal:, hash:, label:, held_text:, aggregates:, edges:, role: nil, projection: nil)
            @db.exec("BEGIN")
            # A concurrent minter blocks briefly, then refuses with a name
            # rather than hanging: mint is non-interactive (the human
            # decision already happened in the audit tool), so the lock is
            # only ever held for the transaction itself.
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
            # After compile_head!, not before — this era's own snapshot
            # table (a possibly-renamed name, per aggregate) is what
            # grant_role! grants on, and compile_head! is what creates it.
            # Granting first would GRANT on a relation that does not
            # exist yet for any aggregate renamed in this very edge.
            aggregates.each { |aggregate| compile_head!(aggregate, ordinal, label, edges) }
            grant_role!(role, aggregates: aggregates, era: ordinal) if role
            # **Last, right before `COMMIT`** — not merely unconditional. Once
            # acquired, a lock is held until the transaction ends, not
            # just for the statement that took it — so advance_era!'s
            # DROP POLICY/CREATE POLICY (AccessExclusiveLock, same family
            # as ALTER TABLE, and unavoidably so: Postgres has no lighter
            # form for changing a policy, unlike the partition attach
            # below) blocks every concurrent writer for as long as it sits
            # before the expensive step. Ordered here, that block is the
            # width of a few catalog statements plus the commit itself,
            # not the width of compile_head!'s matview build. Measured, not
            # assumed: placed above compile_head!, this reintroduces
            # exactly the mint-stops-the-world cost ensure_partition!'s
            # build-then-ATTACH exists to avoid — a cost only a genuine
            # concurrent-write test shows.
            #
            # Unconditional regardless of position — this is the line that
            # drops writing to the old schema. It does not wait for a role
            # to be configured on this boot, because the cutoff is a fact
            # about the era, not about who happened to mint it: an old
            # checkout's role, granted by some earlier boot this one knows
            # nothing about, must lose write access the instant this
            # transaction commits.
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
          # Base privileges for a deployment's app role — a non-owner,
          # which may append and read once the shared era fence below
          # admits it, and owns nothing. Idempotent, and unconcerned with
          # which era is current: that is advance_era!'s job, not this
          # one's, so a role can be onboarded at any time without
          # disturbing who may write what right now.
          #
          # Owner-only work, so a non-owner app boot skips it: the
          # provisioner has already granted that role, and re-affirming is
          # idempotent anyway.
          #
          # `aggregates:`/`era:` cover the read-cache side of the same
          # story: unlike the journal (immutable, owner-provisioned once),
          # each aggregate's head_snapshot table is a table an app role
          # must itself `INSERT`/`UPDATE`/`DELETE` into — PostgresEra#append writes
          # it directly, not through a view — so it needs real DML grants,
          # not just the SELECT a derived read surface would need. `era:`
          # is the ordinal this role is about to write under (the one
          # hold_first!/mint_era! just made current, or the superseded one
          # a stale checkout still speaks) — head_snapshot is era-scoped,
          # so granting on the wrong era's table would grant on a table
          # this role will never touch. Every caller passes its own
          # bluebook's aggregates and resolved era — including a
          # held-but-superseded checkout, since a role connecting to it
          # for the first time (a new instance of an old checkout) has no
          # privileges yet either.
          #
          # @param role [String] name of the Postgres role to grant to
          # @param aggregates [Array<Bluebook::Aggregate>] aggregates whose head snapshot table,
          #   and head view where one exists, the role is granted on; ignored when `era` is nil
          # @param era [Integer, nil] ordinal of the era whose snapshot tables to grant on; nil
          #   grants only the journal and sequence privileges
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a grant, such as one naming a role or a
          #   snapshot table that does not exist
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
          # The current-era fence — one policy, shared by every granted
          # role, not one per role. Advancing it is what drops writing to
          # the old schema the instant the new one materializes: the
          # moment this commits, no role — old or new, whether or not it
          # did anything to earn this mint — may insert anything but the
          # era named here. There is no persisted fork: a checkout that
          # keeps a role fenced to a stale era does not exist in this
          # design, because there is no such thing as a role fenced to an
          # era at all — only the one era everyone currently shares.
          #
          # A row policy, not a partition grant. Postgres checks INSERT
          # privilege on the partitioned parent for a routed insert and
          # never consults the partition's own grants, so a per-partition
          # GRANT/REVOKE is inert in both directions: grant only on the
          # partition and nobody can write at all; grant on the parent and
          # they may write into every era, ancestors included. Measured,
          # not reasoned about — see the spec, which writes through the
          # fence rather than asserting the catalog.
          #
          # The table owner bypasses RLS by default, and that is load
          # bearing: mint and merge run as the owner and must be able to
          # write any era (the merge re-enters a winner's state into the
          # current era, and compile_head! reads every ancestor).
          #
          # Call only with the new current ordinal — from hold_first! (era
          # 1) or mint_era! (era N). Calling this with a superseded
          # ordinal — from a boot that merely recognizes an old checkout —
          # would roll the fence backward and silently reopen the old
          # schema for everyone. That path grants a role's privileges
          # (grant_role!) and stops there on purpose.
          #
          # @param ordinal [Integer] ordinal of the era that becomes the only writable one
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the policy change, as it does for a role that
          #   does not own the journal
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
