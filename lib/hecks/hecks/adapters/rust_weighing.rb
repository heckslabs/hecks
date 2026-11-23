# frozen_string_literal: true

require "hecks/rust_build/gone_prune"
require "hecks/rust_build/build_lock"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Gauging` port's adapter for `RustCare`: on a beat, says the Rust build dirs are due a
    # prune when the volume's free gigabytes fall under the Hecks world's `disk_space`
    # `rising_free_gb` (mode `pressure`), or when a build dir's worktree is gone (mode `gone`).
    # Room enough with nothing gone, or a Rust build holding the build lock, is deferred by name.
    # It reads the volume and the directory listing and deletes nothing.
    class RustWeighing
      # The Hecks world verb that carries the line.
      VERB = "disk_space"

      # Free gigabytes the volume keeps before the prune is due, if the world names none.
      FREE_GB = 60

      # @param registry [Runtime::Registry, nil] the booted registry whose world names the line
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `free_gb:` a stand-in reading, `gone:` a stand-in count of gone
      #   dirs (a callable), `locked:` a stand-in for a held build lock (a callable)
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @settings = settings
      end

      # @param _held [Hash] the `RustCare` record: `run`; unused
      # @return [Hash{Symbol => Hash}] `reason` and `mode`
      # @raise [ConsoleCapture::Failure] naming why the build dirs are left for the next beat
      def weigh(**_held)
        raise ConsoleCapture::Failure, "deferred: a Rust build holds the build lock" if building?

        free = free_gb
        return due("#{free} GB free, under #{line}", "pressure") if free < line

        raise ConsoleCapture::Failure, "deferred: #{free} GB free and no gone worktree's build dir" unless gone?

        due("a build dir's worktree is gone", "gone")
      end

      private

      def due(reason, mode) = { reason: { value: reason }, mode: { value: mode } }

      def line
        declared = @registry&.world("Hecks")&.for_verb(VERB) || {}
        declared[:rising_free_gb] || FREE_GB
      end

      def free_gb = @settings[:free_gb] || df_gb

      def df_gb = IO.popen(["df", "-Pk", Dir.pwd], err: File::NULL, &:read).lines.last.to_s.split[3].to_i / 1_048_576

      def gone? = @settings[:gone] ? @settings[:gone].call : RustBuild::GonePrune.any?

      def building? = @settings[:locked] ? @settings[:locked].call : RustBuild::BuildLock.held?
    end
  end
end
