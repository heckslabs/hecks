# frozen_string_literal: true

require "hecks/runtime/asking"
require "hecks/runtime/errors"
require "hecks/runtime/row_sweep"
require "hecks/hecks/adapters/git_rehearsal"

module Hecks
  module Adapters
    # The `PushDue` port's adapter for `PushNudge`: reads whether a push of local main is due and
    # whether the `push-due` Work row is already open, and answers the flags and numbers the
    # bluebook's policies file, revise or finish the row from.
    #
    # The git reading is `GitRehearsal#due`, called as it is: this class only parses the line it
    # answers and applies the thresholds. It fetches, pushes and merges nothing. The thresholds are
    # the QualityControl world's `push_nudge` setting (`commits:` ahead, `hours:` old), else the
    # defaults below.
    class PushDueReader
      # The thresholds when the world declares none.
      DEFAULTS = { commits: 20, hours: 24 }.freeze

      # The world verb that carries the thresholds.
      VERB = "push_nudge"

      # The key of the one Work row.
      WORK = "push-due"

      # The title of the Work row.
      TITLE = "a push of main is due"

      AHEAD = /(\d+) commit\(s\) ahead/
      OLDEST = /oldest unpushed ([\d.]+) hours/
      # Everything up to the first line break.
      FIRST_LINE = /[^\n]*/

      RED_NOW = /last (?:rehearsal|quick|full): red [^;\n]*\(the current /

      # The thresholds a registry's QualityControl world declares.
      #
      # @param registry [Runtime::Registry, nil]
      # @return [Hash{Symbol => Integer, Float}] `commits:` and `hours:`
      def self.thresholds(registry)
        declared = registry&.world("QualityControl")&.for_verb(VERB) || {}
        merged = DEFAULTS.merge(declared.slice(*DEFAULTS.keys))
        { commits: Integer(merged[:commits]), hours: Float(merged[:hours]) }
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] a directory inside the repository; this repository when nil
      # @param rehearsal [#due, nil] the rehearsal adapter; `GitRehearsal` when nil
      def initialize(aggregate: nil, settings: {}, root: nil, rehearsal: nil)
        @root = root || File.expand_path("../../../..", __dir__)
        @rehearsal = rehearsal || GitRehearsal.new
      end

      # @param _held [Hash] the `PushNudge` record
      # @return [Hash{Symbol => Hash}] `due:` and `raised:` ("yes"/"no"), `work:`, `title:`,
      #   `detail:`
      # @raise [Runtime::GivenNotMet] when the refs cannot be read
      def read(**_held)
        text = @rehearsal.due(checkout: @root).fetch(:text)
        limits = self.class.thresholds(registry)
        { due: flag(due?(text, limits)), raised: flag(raised?), work: { value: WORK }, title: { value: TITLE },
          detail: { value: detail(text, limits) } }
      rescue ConsoleCapture::Failure => e
        raise Runtime::GivenNotMet, "the refs could not be read: #{first_line(e.message)}"
      end

      private

      def detail(text, limits)
        "#{text.delete_prefix("push due: ")} (thresholds: #{limits[:commits]} commits, #{limits[:hours]} hours)"
      end

      def first_line(text) = text[FIRST_LINE].strip

      def due?(text, limits)
        return false unless text.start_with?("push due: yes")

        text[AHEAD, 1].to_i >= limits[:commits] || text[OLDEST, 1].to_f >= limits[:hours] || text.match?(RED_NOW)
      end

      def flag(value) = { value: value ? "yes" : "no" }

      # Whether the push-due row is open now: planned or started.
      def raised?
        sweep = Runtime::RowSweep.new(registry)
        aggregate = sweep.query_aggregate("Tickets", "Work", verb: "Work.Undone")
        sweep.rows("Tickets", aggregate, "Undone", {}).any? { |row| row[:id].to_s == WORK }
      end

      def registry
        Runtime::Asking.registry or raise Runtime::GivenNotMet, "a push is checked only when its PushNudge asks"
      end
    end
  end
end
