# frozen_string_literal: true

module Hecks
  module Adapters
    module InProcessOperations
      # Which repository's event log a follow reads. A database adapter keeps one log for every
      # aggregate; Memory keeps one per aggregate, so the filter has to pick the right one.
      module EventLogs
        private

        # The repository whose event log a follow reads: the named aggregate's when it keeps one,
        # else the first that does.
        #
        # @raise [Runtime::NotFound] when the aggregate is declared by no bluebook, or no adapter
        #   keeps an event log
        def event_repository(domain, registry = nil, aggregate = nil)
          registry ||= boot(domain).registry
          refuse_unknown_aggregate!(domain, registry, aggregate)
          logged = logged_repositories(registry)
          found = logged.find { |declared, _| declared.hecks_name.casecmp?(bare(aggregate)) } || logged.first
          found&.last or raise Runtime::NotFound, "no adapter in #{plain(domain)} persists an event log"
        end

        # A follow of an aggregate no bluebook declares would wait on another aggregate's log and
        # drop every event, so a misspelt name is refused by name.
        def refuse_unknown_aggregate!(domain, registry, aggregate)
          return if bare(aggregate).empty?
          return if registry.bluebooks.values.any? { |bluebook| declares?(bluebook, bare(aggregate)) }

          raise Runtime::NotFound, "no aggregate #{plain(aggregate).inspect} in #{plain(domain)}"
        end

        def declares?(bluebook, name) = bluebook.aggregates.any? { |declared| declared.hecks_name.casecmp?(name) }

        # The aggregate's bare name: a qualified one loses its modules.
        def bare(aggregate) = Naming.demodulise(plain(aggregate).to_s)

        # Each aggregate with its repository, for the repositories that keep an event log.
        def logged_repositories(registry)
          pairs = registry.bluebooks.flat_map do |name, bluebook|
            bluebook.aggregates.map { |declared| [declared, registry.repository(name, declared)] }
          end
          pairs.select { |_, repository| repository.respond_to?(:events) }
        end
      end
    end
  end
end
