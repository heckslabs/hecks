require_relative "../lineage"
require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "ledger_change"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # The era check of a world that declares `disposable_ledger true` in its PostgresEra
        # `persisted_by` block: a tooling ledger whose rows are worth keeping, not worth an era.
        #
        # Its boot never refuses as unminted or superseded and needs no edge, mint or rehearsal. It
        # holds the first era itself, and on a shape change it re-holds the latest era at the
        # booting shape: an added aggregate gets a head, a widened one keeps its rows as they are,
        # and a replaced one has its rows moved to a dated archive table and starts empty. It names
        # each archive on stderr. A world without the setting never reaches this module.
        module DisposableLedger
          module_function

          # Whether a world's persistence settings declare the ledger disposable, spelled as a
          # boolean or as the word. Unset is false, so every other world keeps its era guard.
          #
          # @param settings [Hash{Symbol, String => Object}] the persistence settings of the boot
          # @return [Boolean]
          def declared?(settings) = [true, "true"].include?(PostgresEra.setting(settings, :disposable_ledger, default: false))

          # Brings the ledger to the booting shape and records the era the boot reads.
          #
          # @param registry [Runtime::Registry] the booting registry; `resolved_eras` is set
          # @param bluebook [Bluebook::Declaration] the bluebook booting now
          # @param current_text [String] its source text, held as the era's text
          # @param settings [Hash{Symbol, String => Object}] the persistence settings of the boot
          # @return [nil] a disposable ledger's boot mints no era
          # @raise [Runtime::WiringError] if the connection is refused or its role is unfenced
          def check!(registry:, bluebook:, current_text:, settings:)
            db = PostgresEra.connect_for(bluebook.name, settings, provision: true)
            lineage = open_lineage(db, bluebook, settings)
            registry.resolved_eras[bluebook.name] = locked(db, bluebook.name) { reconcile!(lineage, bluebook, current_text) }
            grant!(lineage, bluebook, settings, registry.resolved_eras[bluebook.name])
            nil
          ensure
            db&.close
          end

          # The ordinal the ledger holds once it is at the booting shape.
          #
          # @return [Integer]
          def reconcile!(lineage, bluebook, text)
            latest = lineage.eras.last
            return hold_first!(lineage, bluebook, text) unless latest

            change = LedgerChange.between(held_projection(latest), bluebook)
            apply!(lineage, bluebook, text, change, latest[:ordinal]) if change.changed?
            latest[:ordinal]
          end

          # Archives every replaced aggregate, gives each added or replaced one a head over the
          # latest era alone, provisions the read side of every aggregate, and re-holds the era.
          def apply!(lineage, bluebook, text, change, ordinal)
            stamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
            change.replaced.each { |name| archive!(lineage, bluebook, change.storage_name(bluebook, name), stamp) }
            fresh_heads!(lineage, bluebook, change, ordinal)
            bluebook.aggregates.each { |aggregate| lineage.provision_read_side!(aggregate, ordinal) }
            lineage.rehold!(ordinal, text, Runtime::StorageShape.project(bluebook), Runtime::StorageShape.mint_hash(bluebook))
          end

          # Gives every added or replaced aggregate the booting bluebook declares a head over the
          # latest era alone: none of its rows are in an earlier era.
          def fresh_heads!(lineage, bluebook, change, ordinal)
            (change.added + change.replaced).filter_map { |name| bluebook.aggregate(name) }
                                            .each { |aggregate| lineage.fresh_head!(aggregate.storage_name, ordinal) }
          end

          def archive!(lineage, bluebook, storage_name, stamp)
            archive, count = lineage.archive_aggregate!(storage_name, stamp)
            warn "[hecks] #{bluebook.name}: the shape of #{storage_name} changed in a way its rows do not fit; " \
                 "archived #{count} journal row#{"s" unless count == 1} to #{archive} and started it empty " \
                 "(disposable_ledger)"
          end

          def hold_first!(lineage, bluebook, text)
            lineage.hold_first!(text, projection: Runtime::StorageShape.project(bluebook))
            lineage.provision_first_era!(bluebook.aggregates)
            1
          end

          # The storage shape the latest era holds: the projection its hold recorded, else the
          # shape its held text declares.
          def held_projection(era) = era[:projection] || Runtime::StorageShape.project(LineageManager.shadow(era[:held_text]))

          def open_lineage(db, bluebook, settings)
            lineage = Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as)
            lineage.check_fence_applies!(allow_superuser: PostgresEra.setting(settings, :allow_superuser, default: false))
            lineage.ensure_base!
            lineage
          end

          # Holds the domain's era lock, the one a mint takes, for the whole reconcile, so two boots
          # of a changed shape archive once.
          def locked(db, domain)
            db.exec_params("SELECT pg_advisory_lock(hashtext('hecks_eras:' || $1))", [domain])
            yield
          ensure
            db.exec_params("SELECT pg_advisory_unlock(hashtext('hecks_eras:' || $1))", [domain])
          end

          def grant!(lineage, bluebook, settings, ordinal)
            role = PostgresEra.setting(settings, :role)
            lineage.grant_role!(role.to_s, aggregates: bluebook.aggregates, era: ordinal) unless role.to_s.empty?
          end
        end
      end
    end
  end
end
