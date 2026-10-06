# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaPostgresMigrate
      # The copy step of `sweep.migrate_ledger_from_heki`: one `save` per Heki id into the
      # repository the domain binds today, sorted into migrated, skipped and refused.
      module Copying
        private

        # @return [Array<Array<String>>] the ids migrated, skipped and refused
        def copy(candidates, registry, heki_dir, force)
          buckets = { migrated: [], skipped: [], conflicts: [] }
          candidates.each { |candidate| copy_candidate(candidate, registry, heki_dir, force, buckets) }
          buckets.values_at(:migrated, :skipped, :conflicts)
        end

        def copy_candidate(candidate, registry, heki_dir, force, buckets)
          aggregate = candidate[:aggregate]
          # Guarded like a factory-built repository so a Heki store decodes through the state codec.
          source = Hecks::Ports::Persistence::CodecBoundary.guard!(
            Hecks::Adapters::Heki.new(aggregate: aggregate, settings: { dir: heki_dir }, root: nil)
          )
          dest = registry.repository(candidate[:domain_name], aggregate)
          source.all.each do |instance|
            buckets[copy_instance(dest, instance, force)] << "#{aggregate.storage_name}/#{instance.id}"
          end
        end

        # @return [Symbol] the bucket the instance falls in: `:migrated`, `:skipped` or `:conflicts`
        def copy_instance(dest, instance, force)
          existing = dest.find(instance.id)
          if existing.nil?
            dest.save(instance) if force
            :migrated
          elsif self.class.canonical(existing.state) == self.class.canonical(instance.state)
            :skipped
          else
            :conflicts
          end
        end
      end
    end
  end
end
