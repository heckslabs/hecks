require_relative "replay"
require_relative "differential/wire_comparison"
require_relative "engine/ruby_engine"
require_relative "engine/kernel_engine"

module Hecks
  module Fuzzing
    # The seam between a step list and whatever runs it: an engine answers
    # `call(domain_path, steps)` with a history hash in the shape `Replay.call` returns.
    # {RubyEngine} is the in-process runtime; {KernelEngine} is a Rust kernel spoken to over the
    # host protocol (ADR 0189). Both give the same history for the fields the wire carries.
    module Engine
      # The wire fields a kernel session carries today; queries and sagas are not on its wire.
      CARRIED = %i[instances events refusals dry_runs].freeze

      module_function

      # A history in the wire shapes of `Differential::WireComparison`, cut to what the kernel
      # session carries. A refusal keeps its verb only: the kernel's session answer names neither
      # the kind nor the Ruby wording.
      #
      # @param history [Hash] what an engine's `call` returned
      # @return [Hash{Symbol => Object}] the fields in `Engine::CARRIED`
      def wire_view(history)
        view = Differential::WireComparison.ruby_view({ queries: [], sagas: [], dry_runs: [] }.merge(history))
        view = view.slice(*CARRIED)
        view.merge(refusals: view[:refusals].map { |row| row.slice("verb") })
      end
    end
  end
end
