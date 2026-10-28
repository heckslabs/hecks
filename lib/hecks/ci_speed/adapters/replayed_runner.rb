# frozen_string_literal: true

require "hecks/ci_speed/adapters/local_runner"

module Hecks
  module Adapters
    # A `LocalRunner` that replays samples recorded here instead of running anything, for
    # `ci_speed.behaviors`: a behaviors boot must be deterministic and fast, and the real adapter
    # makes two checkouts and times real work. The verdict, the saving and the estimate are worked
    # out by the real adapter's own `Verdict` and `Answer`, so only the timing is replaced.
    class ReplayedRunner
      # The samples each experiment name replays, in seconds, as base and candidate.
      RECORDINGS = {
        "wide_win"     => { base: [120.0, 122.0, 124.0], candidate: [90.0, 91.0, 92.0] },
        "within_noise" => { base: [120.0, 126.0, 123.0], candidate: [121.0, 124.0, 122.0] },
        "wide_loss"    => { base: [90.0, 91.0, 92.0], candidate: [120.0, 122.0, 124.0] }
      }.freeze

      # The load average every replay reports.
      LOAD = 2.5

      # @param aggregate [Object, nil] unused
      def initialize(aggregate: nil); end

      # @param held [Hash] the `Experiment` record
      # @return [Hash{Symbol => Hash}] the answer, as the real adapter words it
      # @raise [LocalRunner::Refused] when nothing is recorded for the experiment's name
      def measure(**held)
        asked = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
        samples = RECORDINGS.fetch(asked.fetch(:name)) do
          raise LocalRunner::Refused, "no samples are recorded for #{asked[:name]}; recorded: #{RECORDINGS.keys.join(", ")}"
        end
        verdict = LocalRunner::Verdict.new(**samples)
        LocalRunner::Answer.build(asked: asked, definition: asked.fetch(:measures), verdict: verdict, load: LOAD,
                                  unmeasured: [])
      end
    end
  end
end
