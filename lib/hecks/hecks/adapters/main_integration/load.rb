# frozen_string_literal: true

require "hecks/rust_build/world_rows"

module Hecks
  module Adapters
    class MainIntegration
      # How hard a verification of a landed commit may work in its clean copy: the Tickets world's
      # `main_verification` line sets the workers one check may start (`workers`, handed on as
      # `PARALLEL_PROCESSOR_COUNT`, which the quick gate's parallel runs and RuboCop read) and the
      # `nice` increment its commands run under, so a verification beside a coder and an architect
      # session keeps the machine under the load a fill stops at. Every check still runs; only
      # fewer of its processes run at once, at a lower priority. A checkout whose world has no
      # such line is left as it was.
      module Load
        # The Tickets world verb that carries the setting.
        VERB = "main_verification"

        # The variable the parallel gem, RuboCop and the gate's worker count read.
        WORKERS = "PARALLEL_PROCESSOR_COUNT"

        module_function

        # @param directory [String] the clean copy a verification runs in
        # @return [Hash] the copy's `main_verification` line, empty when it has none
        def row(directory) = RustBuild::WorldRows.row(directory, VERB)

        # @param directory [String] the clean copy a verification runs in
        # @return [Integer, nil] the most workers one check may start, nil when none is set
        def workers(directory) = (count = row(directory)[:workers]) && Integer(count)

        # @param directory [String] the clean copy a verification runs in
        # @return [Array<String>] the words that go before a check's command: `env` for the worker
        #   cap and `nice` for the increment, whichever the line sets; empty when it sets neither
        def prefix(directory)
          line = row(directory)
          capped = line[:workers] ? ["env", "#{WORKERS}=#{Integer(line[:workers])}"] : []
          niced = line[:nice] ? ["nice", "-n", Integer(line[:nice]).to_s] : []
          [*capped, *niced]
        end
      end
    end
  end
end
