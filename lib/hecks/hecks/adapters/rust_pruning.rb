# frozen_string_literal: true

require "hecks/rust_build/prune"
require "hecks/rust_build/gone_prune"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Trimming` port's adapter for `RustCare`: deletes what a heard look named. Under
    # `pressure` it runs the whole {RustBuild::Prune} (gone worktrees' build dirs and the shared
    # cache's stale artifacts); under `gone` it takes only the build dirs of worktrees git does
    # not list. A failed delete is refused by name.
    class RustPruning
      # @param registry [Runtime::Registry, nil] unused
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `pruner:` a stand-in called with the mode, answering bytes freed
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @pruner = settings[:pruner] || method(:prune)
      end

      # @param held [Hash] the `RustCare` record: `run`, `mode`
      # @return [Hash{Symbol => Hash}] `outcome`, the megabytes freed
      # @raise [ConsoleCapture::Failure] when the delete fails
      def trim(**held)
        mode = plain(held[:mode])
        freed = @pruner.call(mode)
        { outcome: { value: "freed #{freed / 1_048_576} MB of Rust builds (#{mode})" } }
      rescue SystemCallError => e
        raise ConsoleCapture::Failure, "refused: #{e.message}"
      end

      private

      def prune(mode) = mode == "pressure" ? RustBuild::Prune.run : RustBuild::GonePrune.run

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
