module Hecks
  module Runtime
    class Registry
      # The sentence the saga durability warning adds when a process manager starts on a kept
      # aggregate: a `KeptAggregate` row of the Hecks bluebook's `LocalOverlay`, which the
      # development pipeline reads back in a later process. The fix is then the checkout's overlay,
      # not a new adapter. Mixed into {DurabilityWarnings}; the rows are read from the IR.
      module KeptSagaNote
        private

        # @param domain [String] the domain declaring the process managers
        # @param undurable [Array<Bluebook::ProcessManager>] the process managers no store keeps
        # @return [String] the sentence, empty when none starts on a kept aggregate
        def kept_saga_note(domain, undurable)
          kept = kept_aggregate_names(domain)
          starters = undurable.flat_map { |declared| starting_aggregates(domain, declared.starts_on.to_s) }
          names = starters.map { |aggregate| aggregate.hecks_name.to_s }.select { |name| kept.include?(name) }.uniq
          return "" if names.empty?

          " #{names.join(", ")} is on the dev pipeline's kept list: write this " \
            "checkout's overlay with `exe/hecks LocalOverlay.write!`."
        end

        def kept_aggregate_names(domain)
          kept_rows.select { |row| row[:domain].to_s == domain.to_s }.map { |row| row[:aggregate].to_s }
        end

        def kept_rows
          shape = kept_owner&.value_objects&.find { |object| object.hecks_name == "KeptAggregate" }
          Array(shape&.members).map(&:to_h)
        end

        def kept_owner = bluebook("Hecks")&.aggregates&.find { |aggregate| aggregate.hecks_name == "LocalOverlay" }
      end
    end
  end
end
