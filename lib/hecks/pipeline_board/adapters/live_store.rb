# frozen_string_literal: true

require_relative "probe"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    module PipelineBoard
      # The records of the store another checkout keeps (the owner's, which the board is pointed at
      # with `PIPELINE_BOARD_LAUNCHER_ROOT`), read in this process. The checkout's Hecks domain is
      # booted once, on the first read and without the writes a boot makes, and kept; each read asks
      # its repositories, so the board spawns no launcher to see the live store. It only reads.
      class LiveStore
        # Where a checkout declares its Hecks domain.
        DOMAIN_PATH = "lib/hecks/hecks"

        # @param root [String] the checkout whose store is read
        # @param booter [#call, nil] takes the domain directory and answers a booted runtime; stands
        #   in for the real boot
        def initialize(root:, booter: nil)
          @root = root
          @booter = booter || method(:boot)
          @lock = Mutex.new
        end

        # @param domain [String] a bluebook of the checkout's domain, such as `"Hecks"`
        # @param name [String] an aggregate of it, such as `"AgentRun"`
        # @return [Array<Object>] every record of the aggregate
        # @raise [Unavailable] when the checkout cannot be booted or does not declare the aggregate
        def records(domain, name)
          registry = runtime.registry
          aggregate = registry.bluebook(domain)&.aggregates&.find { |candidate| candidate.hecks_name == name }
          raise Unavailable, "the live store at #{@root} declares no #{domain}.#{name}" unless aggregate

          registry.repository(domain, aggregate).all
        end

        private

        def runtime
          @lock.synchronize { @runtime ||= @booter.call(File.join(@root, DOMAIN_PATH)) }
        rescue Unavailable then raise
        rescue StandardError => e
          raise Unavailable, "the live store at #{@root} did not open: #{first_line(e.message)}"
        end

        def first_line(text) = text.to_s.tr("\n", " ")[0, 160]

        def boot(directory)
          described = Hecks.describe(directory)
          Hecks.boot_described(described, install_driving: false, read_only: true)
        end
      end
    end
  end
end
