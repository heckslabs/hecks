require_relative "../field_cache_provisioner"

module Hecks
  module Adapters
    class PostgresRevision
      class Lineage
        # The read side of an era that the mint path provisions: each aggregate's head view and the
        # field caches its queries narrow by. The mint that compiles an era and the first-era hold
        # call these; nothing a boot reads does.
        module MintProvisioning
          # Creates and backfills one aggregate's field caches for an era, on this lineage's
          # connection, so the caches commit with the era that owns them.
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate whose where-fields are cached
          # @param era [Integer] the ordinal of the era the caches belong to
          # @return [Hash{String => String}] each cached field mapped to its cache table
          # @raise [PG::Error] if Postgres refuses the DDL, a source read or an upsert
          def provision_read_side!(aggregate, era)
            FieldCacheProvisioner.new(self, aggregate, era).provision!
          end

          # Holds the read side of the first era: each aggregate's head view over the snapshot the
          # first era holds, then its field caches, then the app role's privileges on them, as a
          # mint grants them for a later era.
          #
          # @param aggregates [Array<Bluebook::Aggregate>] the domain's aggregates
          # @param role [String, nil] the app role to grant; none when blank
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a statement
          def provision_first_era!(aggregates, role: nil)
            aggregates.each do |aggregate|
              ensure_first_head!(aggregate.storage_name)
              provision_read_side!(aggregate, 1)
            end
            grant_role!(role, aggregates: aggregates, era: 1)
          end

          # Holds era 1 and provisions its read side in one transaction under the domain's era lock,
          # so a crash leaves either all of it or none. A run that finds era 1 already held from the
          # same text with some head view missing (a half-done run of an older version) completes
          # it; any other held era is refused.
          #
          # @param text [String] the bluebook source the first era freezes
          # @param projection [Hash, nil] the storage-shape projection of the text
          # @param aggregates [Array<Bluebook::Aggregate>] the domain's aggregates
          # @param role [String, nil] the app role to grant; nil or empty grants nothing
          # @return [void]
          # @raise [Runtime::WiringError] if another era is held, the lock is not granted in 10s,
          #   or Postgres refuses a statement; the transaction rolls back first
          def hold_first_era!(text, projection:, aggregates:, role: nil)
            lock_era_table!
            refuse_second_hold!(text, aggregates)
            hold_first!(text, projection: projection)
            provision_first_era!(aggregates, role: role)
            @db.exec("COMMIT")
          rescue StandardError
            rollback_quietly
            raise
          end

          private

          def lock_era_table!
            @db.exec("BEGIN")
            @db.exec("SET LOCAL lock_timeout = '10s'")
            @db.exec("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:' || #{text_literal(@domain)}))")
          end

          # Refuses unless no era is held, or only era 1, from `text`, is held and unfinished.
          def refuse_second_hold!(text, aggregates)
            held = eras
            return if held.empty?
            return if held.size == 1 && held.first[:held_text] == text && unfinished?(aggregates)

            raise Runtime::WiringError, "#{@domain} already holds an era"
          end

          def unfinished?(aggregates)
            aggregates.any? { |aggregate| !table_exists?(head_view(aggregate.storage_name)) }
          end
        end
      end
    end
  end
end
