# frozen_string_literal: true

require "hecks/signalbox/adapters/looking"

module Hecks
  module Adapters
    # A `Looking` that replays looks recorded here instead of reading git, the machine and Delegate,
    # for `signalbox.behaviors`: a behaviors boot must be deterministic. The answer is worded by the
    # real `Looking`, so only the outside it reads is replaced.
    class ReplayedLooking
      # The main checkout's view: its head is main's tip and it lacks no local file.
      MAIN = { head: "4116a6d", main: "4116a6d", missing: 0 }.freeze

      # Delegate's last fill started a coder and its last shed spared every one.
      STARTED = { fill_subject: "pipeline-board-tiles", fill_delegate: "start", shed_subject: "load-7",
                  shed_delegate: "none" }.freeze

      # The machine on a quiet afternoon, and in the helper storm of 2026-11-18: 33 of 36 gigabytes
      # in use and a load of 34.
      QUIET = { capacity_mb: 36_864, used_mb: 20_463, load: 700, cores: 6 }.freeze
      STORM = { capacity_mb: 36_864, used_mb: 33_000, load: 3_397, cores: 6 }.freeze

      # The looks each beat name replays.
      RECORDINGS = {
        "beat-quiet"    => { view: MAIN, machine: QUIET, delegate: STARTED },
        "beat-storm"    => { view: MAIN, machine: STORM, delegate: STARTED },
        "beat-worktree" => { view: MAIN.merge(head: "9b81245"), machine: QUIET, delegate: STARTED },
        "beat-unread"   => { view: MAIN, machine: { capacity_mb: 0 }, delegate: STARTED }
      }.freeze

      # @param aggregate [Object, nil] unused
      def initialize(aggregate: nil); end

      # @param held [Hash] the `Beat` record: `beat`
      # @return [Hash{Symbol => Hash}] the answer, as the real adapter words it
      # @raise [Looking::Unlooked] when nothing is recorded for the beat, or its machine is unread
      def look(**held)
        beat = held[:beat].is_a?(Hash) ? held[:beat][:value] : held[:beat]
        recorded = RECORDINGS.fetch(beat) { raise Looking::Unlooked, "no look is recorded for #{beat}" }
        stand_ins = recorded.transform_values { |facts| -> { facts } }
        Looking.new(settings: stand_ins.merge(marks: -> { Looking::Marks.new(nil).facts })).look(**held)
      end
    end
  end
end
