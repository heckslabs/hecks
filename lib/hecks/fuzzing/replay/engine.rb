# frozen_string_literal: true

require_relative "../differential"
require_relative "engine/ruby"
require_relative "engine/kernel"

module Hecks
  module Fuzzing
    # The seam a step list is replayed through, so the fuzzer, the shrinker and the corpus can run
    # a sequence on the Ruby runtime or on the Rust kernel without knowing which (ADR 0188 step 9,
    # slice 1 of docs/plans/simulation-tests.md).
    #
    # An engine answers `call(domain_path, steps, identity:)`. {Engine::Ruby} answers the history
    # `Replay.call` returns; {Engine::Kernel} answers the kernel's run output, which carries the
    # same six wire fields (instances, events, refusals, queries, sagas, dry runs). {divergences}
    # holds one to the other through `Differential::WireComparison`, the comparison the
    # QualityControl sweep already makes.
    module Engine
      # The wire fields both engines carry and {divergences} compares.
      WIRE_FIELDS = %w[instances events refusals queries sagas dry_runs].freeze

      module_function

      # Replays `steps` on both engines and lists where their wire views disagree.
      #
      # @param differ [Object] the duck-typed comparison helpers `Differential.diff` takes
      # @param domain_path [String] the domain directory to replay
      # @param steps [Array<Hash>] the step list
      # @param kernel [Engine::Kernel] the kernel engine, built for the domain's feature
      # @param identity [Array<String>, nil] the ids the identity port hands out, in order
      # @return [Array<Hash>] one `{field:, ruby:, rust:}` per disagreeing field; empty when equal
      def divergences(differ, domain_path, steps, kernel:, identity: nil)
        ruby = Ruby.new.call(domain_path, steps, identity: identity)
        output = kernel.call(domain_path, steps, identity: identity)
        Differential.rust_outcomes(differ, ruby, output, kernel.binary, false).fetch(:differential)
      end
    end
  end
end
