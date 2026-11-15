# frozen_string_literal: true

require "hecks/rust_build/world_rows"
require "hecks/pipeline_board/adapters/load_guard"
require_relative "../bounded_capture"

module Hecks
  module Adapters
    class GitShallowCheck
      # How many impacted specs the landing runs at once: the world's `impacted_workers` cap, held
      # to the load room left under the limit a fill stops at (`dispatch_max_load`), so a landing
      # never pushes the machine past the number the fill itself honours.
      module ImpactedWorkers
        # The Tickets world verb that carries the limit.
        LIMIT_VERB = "dispatch_max_load"

        # The limit when the world names none.
        DEFAULT_LIMIT = 10.0

        module_function

        # @param specs [Integer] how many specs are to run
        # @param cap [Integer] the world's most workers
        # @param load [Numeric] the machine's 1-minute load now
        # @param limit [Numeric] the load a fill stops at
        # @return [Integer] workers to start: the cap, held to the load room, never above the specs
        #   and never below one
        def count(specs:, cap:, load:, limit:)
          [[cap, (limit - load).floor, specs].min, 1].max
        end

        # @param root [String] a hecks checkout
        # @param load [#call] answers the machine's 1-minute load
        # @return [#call] given the spec count, the workers its world and the load now allow
        def from_world(root, load: PipelineBoard::LoadGuard.method(:reading))
          lambda do |specs|
            count(specs: specs, cap: BoundedCapture.seconds(root, :impacted_workers), load: load.call,
                  limit: limit_of(root))
          end
        end

        # @param root [String] a hecks checkout
        # @return [Float] the world's `dispatch_max_load` limit, else `DEFAULT_LIMIT`
        def limit_of(root) = Float(RustBuild::WorldRows.row(root, LIMIT_VERB)[:limit] || DEFAULT_LIMIT)
      end
    end
  end
end
