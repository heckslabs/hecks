require_relative "../../hecks"

module Hecks
  module CLI
    # The logic behind `hecks refresh_projections` and Custodian's `Operation.RefreshProjections`:
    # forces every
    # read-model projection a booted domain declares to catch up now, the same catch-up a boot
    # runs lazily on first read.
    module RefreshProjections
      module_function

      # Boots the domain `argv` names and refreshes its projections, as `hecks refresh_projections`
      # does.
      #
      # @param argv [Array<String>] the domain directory, first
      # @param program [String] the name the usage message calls this command by
      # @return [Integer] 0
      # @raise [SystemExit] when `argv` is empty
      def run(argv, program: "hecks refresh_projections")
        domain = argv.first or abort "usage: #{program} <domain>"
        call(Hecks.boot(domain))
        0
      end

      # Refreshes every projection of every bluebook in a booted runtime.
      #
      # @param runtime [Runtime] a booted domain
      # @return [Integer] how many projections were caught up
      def call(runtime)
        registry = runtime.registry
        registry.bluebooks.sum do |domain, bluebook|
          bluebook.aggregates.sum { |aggregate| refresh(registry, domain, aggregate) }
        end
      end

      # Catches one aggregate's projection up, when it declares one.
      #
      # @api private
      # @return [Integer] 1 when a projection was caught up, else 0
      def refresh(registry, domain, aggregate)
        worker = Ports::Projection.worker(registry, domain, aggregate, policy: :refresh)
        return 0 unless worker

        worker.catch_up!
        1
      end
    end
  end
end
