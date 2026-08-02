module Hecksagain
  module Adapters
    class Postgres
      class Lineage
        module MintTransaction
          # ── the mint transaction ───────────────────────────────────────
          #
          # One transaction: the new era row (held text + minted name +
          # cut watermark), the new partition, and every aggregate's
          # recompiled matview + head view. The advisory lock is the
          # writer fence — two concurrent minters serialize, and the
          # second finds the era already held. Populating the matview
          # inside the transaction means a convert meeting an unmapped
          # value REFUSES the whole mint, loudly, before anything boots.
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
              "INSERT INTO hecks_eras (domain, ordinal, hash, label, held_text, watermark, held_digest, held_projection, canon_form) " \
              "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
              [@domain, ordinal, hash, label, held_text, watermark, Digest::SHA256.hexdigest(held_text),
               projection && JSON.generate(projection), Runtime::StorageShape::FORM_VERSION]
            )
            archive_text!(ordinal, held_text)
            ensure_partition!(ordinal)
            grant_role!(role) if role
            aggregates.each { |aggregate| compile_head!(aggregate, ordinal, label, edges) }
            # LAST, right before COMMIT — not merely unconditional. Once
            # acquired, a lock is held until the TRANSACTION ends, not
            # just for the statement that took it — so advance_era!'s
            # DROP POLICY/CREATE POLICY (AccessExclusiveLock, same family
            # as ALTER TABLE, and unavoidably so: Postgres has no lighter
            # form for changing a policy, unlike the partition attach
            # below) blocks every concurrent writer for as long as it sits
            # BEFORE the expensive step. Ordered here, that block is the
            # width of a few catalog statements plus the commit itself,
            # not the width of compile_head!'s matview build. Measured:
            # moving this above compile_head! (an earlier ordering, caught
            # only once a genuine concurrent-write test was built rather
            # than assumed) reintroduced exactly the mint-stops-the-world
            # cost ensure_partition!'s build-then-ATTACH exists to avoid.
            #
            # UNCONDITIONAL regardless of position — this is the line that
            # drops writing to the old schema. It does not wait for a role
            # to be configured on THIS boot, because the cutoff is a fact
            # about the era, not about who happened to mint it: an old
            # checkout's role, granted by some earlier boot this one knows
            # nothing about, must lose write access the instant this
            # transaction commits.
            advance_era!(ordinal)
            @db.exec("COMMIT")
            true
          rescue PG::LockNotAvailable
            @db.exec("ROLLBACK") rescue nil
            raise Runtime::WiringError,
                  "cannot mint era #{ordinal} of #{@domain}: another mint holds the domain lock — " \
                  "waited 10s; try again shortly"
          rescue PG::Error => error
            @db.exec("ROLLBACK") rescue nil
            raise Runtime::WiringError, "cannot mint era #{ordinal} of #{@domain}: #{error.message.strip}"
          end

          # Base privileges for a deployment's app role — a NON-owner,
          # which may append and read once the shared era fence below
          # admits it, and owns nothing. Idempotent, and unconcerned with
          # WHICH era is current: that is advance_era!'s job, not this
          # one's, so a role can be onboarded at any time without
          # disturbing who may write what right now.
          #
          # Owner-only work, so a non-owner app boot skips it: the
          # provisioner has already granted that role, and re-affirming is
          # idempotent anyway.
          def grant_role!(role)
            return unless provisioner?

            quoted_role = quote(role)
            @db.exec("GRANT INSERT, SELECT ON #{quoted_journal} TO #{quoted_role}")
            @db.exec("GRANT USAGE ON SEQUENCE #{quote(sequence)} TO #{quoted_role}")
          end

          # THE current-era fence — ONE policy, shared by every granted
          # role, not one per role. Advancing it is what drops writing to
          # the old schema the instant the new one materializes: the
          # moment this commits, no role — old or new, whether or not it
          # did anything to earn this mint — may insert anything but the
          # era named here. There is no persisted fork: a checkout that
          # keeps a role fenced to a stale era does not exist in this
          # design, because there is no such thing as a role fenced to an
          # era at all — only the ONE era everyone currently shares.
          #
          # A ROW POLICY, not a partition grant. Postgres checks INSERT
          # privilege on the partitioned PARENT for a routed insert and
          # never consults the partition's own grants, so a per-partition
          # GRANT/REVOKE is inert in both directions: grant only on the
          # partition and nobody can write at all; grant on the parent and
          # they may write into EVERY era, ancestors included. Measured,
          # not reasoned about — see the spec, which writes through the
          # fence rather than asserting the catalog.
          #
          # The table owner bypasses RLS by default, and that is load
          # bearing: mint and merge run as the owner and must be able to
          # write any era (the merge re-enters a winner's state into the
          # CURRENT era, and compile_head! reads every ancestor).
          #
          # CALL ONLY WITH THE NEW CURRENT ORDINAL — from hold_first! (era
          # 1) or mint_era! (era N). Calling this with a SUPERSEDED
          # ordinal — from a boot that merely recognizes an old checkout —
          # would roll the fence backward and silently reopen the old
          # schema for everyone. That path grants a role's PRIVILEGES
          # (grant_role!) and stops there on purpose.
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
