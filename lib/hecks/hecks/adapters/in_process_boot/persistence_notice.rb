# frozen_string_literal: true

require "hecks"

module Hecks
  module Adapters
    class InProcessBoot
      # The notice `hecks stores` and `hecks history` give when nothing is persisted. Hecks is in
      # Memory unless a local hecksagon opts it in (ADR 0136), so a fresh process holds no records
      # and no journal, and the plain JSON they print would read as an empty store rather than as a
      # store that was never kept.
      module PersistenceNotice
        module_function

        # The notice when every aggregate of the booted domain is in Memory; the caller says it on
        # standard error, which keeps standard output the JSON document the command promises.
        #
        # @param registry [Runtime::Registry] a booted domain's registry
        # @param program [String] the name the notice calls the command by
        # @return [String, nil] the notice, or nil when something is persisted
        def notice(registry, program:)
          "#{program}: #{message_for(registry)}" unless persisted?(registry)
        end

        # @param registry [Runtime::Registry] a booted domain's registry
        # @return [Boolean] whether any aggregate is bound to a store other than Memory
        def persisted?(registry)
          adapters(registry).any? { |adapter| adapter != Ports::Persistence::DEFAULT_ADAPTER }
        end

        # @param registry [Runtime::Registry] a booted domain's registry
        # @return [Array<String>] the adapter each aggregate of each bluebook resolves to
        def adapters(registry)
          registry.bluebooks.flat_map do |name, bluebook|
            bluebook.aggregates.map { |aggregate| Ports::Persistence::BindingPolicy.resolve(registry, name, aggregate).adapter }
          end
        end

        # @param registry [Runtime::Registry] a booted domain's registry
        # @return [String] what is true of this run and how to keep records instead
        def message_for(registry)
          "nothing is persisted: #{adapters(registry).size} aggregates are in Memory, so this process holds no " \
            "records and no history. To keep them, add a hecks.local.hecksagon with `persisted_by \"Postgres\"` " \
            "and `revisions true`, and a hecks.local.world with `default_database` (ADR 0136)."
        end
      end
    end
  end
end
