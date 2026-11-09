# frozen_string_literal: true

require_relative "probe"
require_relative "registry_store"
require_relative "live_store/opening"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    module PipelineBoard
      # The records of the store another checkout keeps (the owner's, which the board is pointed at
      # with `PIPELINE_BOARD_LAUNCHER_ROOT`), read in this process. The checkout's Hecks domain is
      # booted once, on its own thread and without the writes a boot makes, kept while the
      # checkout's declarations stand, and booted again when one changes; each read asks its
      # repositories, so the board spawns no launcher to see the live store. It only reads.
      #
      # A boot is read-only in what it adds, not at the file: the Sqlite adapter has no read-only
      # mode, so it opens each database and runs its `CREATE TABLE IF NOT EXISTS` and ensure-column
      # statements. Against a database the owner's launcher has already opened, those change
      # nothing; against one missing a column they add it, as the owner's next launcher boot would.
      class LiveStore < RegistryStore
        # Where a checkout declares its Hecks domain.
        DOMAIN_PATH = "lib/hecks/hecks"

        # @param root [String] the checkout whose store is read
        # @param booter [#call, nil] takes the domain directory and answers a booted runtime; stands
        #   in for the real boot
        # @param timing [Hash] `retry:`, `check:` and `wait:` seconds of the {Opening}
        # @param kept [Hash] `clock:` and `cache_seconds:`, as for {RegistryStore}
        def initialize(root:, booter: nil, timing: {}, **kept)
          super(**kept)
          @root = root
          @opening = Opening.new(root: root, directory: File.join(root, DOMAIN_PATH), booter: booter || method(:boot),
                                 clock: kept.fetch(:clock, MONOTONIC), timing: timing)
        end

        # Starts the boot of the checkout's domain without waiting for it, so the first read
        # finds it
        # going or done.
        # @return [LiveStore] self
        def warm
          @opening.warm
          self
        end

        # @return [String, nil] why the last reload failed while the old runtime serves, nil when
        #   the store is current
        def problem = @opening.problem

        private

        def registry = @opening.registry

        def label = "the live store at #{@root}"

        def boot(directory)
          described = Hecks.describe(directory)
          Hecks.boot_described(described, install_driving: false, read_only: true)
        end
      end
    end
  end
end
