module Hecks
  module Bluebook
    module ModelCheck
      # The check over persistence: a hecksagon that wires a store for some aggregates and neither
      # binds the rest nor sets a domain default leaves them in Memory, and their records are lost
      # at exit. An aggregate meant to stay there says so with `Domain::Aggregate.persisted_by("Memory")`;
      # a domain that wires nothing, or sets a default, is left alone.
      module PersistenceChecks
        # @param bluebook [Bluebook::Declaration] the domain being checked
        # @param hecksagon [Bluebook::Hecksagon, nil] its wiring; `nil` checks nothing
        # @return [Array<Finding>] one `:memory_in_persisted_domain` error per unbound aggregate
        def persistence_findings(bluebook, hecksagon)
          return [] if hecksagon.nil?

          binds = hecksagon.binds.select { |bind| bind.verb.to_s == "persisted_by" }
          store = binds.find { |bind| !bind.aggregate.nil? && bind.adapter.to_s != "Memory" }
          return [] if store.nil? || binds.any? { |bind| bind.aggregate.nil? }

          kept = binds.map(&:aggregate_name)
          bluebook.aggregates.reject { |aggregate| kept.include?(aggregate.hecks_name.to_s) }
                  .map { |aggregate| memory_finding(bluebook, aggregate, store.adapter) }
        end

        # @return [Finding] the error naming the aggregate and the hecksagon line to add
        def memory_finding(bluebook, aggregate, adapter)
          line = "#{bluebook.name}::#{aggregate.hecks_name}.persisted_by(#{adapter.to_s.inspect})"
          Finding.new(kind: :memory_in_persisted_domain, severity: :error, subject: aggregate.hecks_name.to_s,
                      message: "#{bluebook.name}'s hecksagon persists other aggregates but binds this one to " \
                               "nothing, so it stays in Memory; add `#{line}` to the hecksagon, or " \
                               "`#{bluebook.name}::#{aggregate.hecks_name}.persisted_by(\"Memory\")` to keep it there")
        end
      end
    end
  end
end
