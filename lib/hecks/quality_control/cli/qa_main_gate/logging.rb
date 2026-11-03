# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaMainGate
      # Turns one red check into one QA bug, proven by the check's own output, and triages it. A
      # check the
      # command can fix mechanically is `self_contained`; every other is `bigger`, for the owner.
      module Logging
        # Checks with a mechanical fixer. `rubocop -a` fixes style offenses it can fix; metrics and
        # the
        # rest need a person.
        SELF_CONTAINED = %w[rubocop].freeze
        SUBMITTER = "qa_main_gate"
        NAME_PREFIX = "main-red-"

        # A bug already open for the same check is not logged again: the commit moved, the red did
        # not.
        # @return [Array(String, String, Boolean)] the reference, its disposition, and whether it
        #   was new
        def log_red(sweep, result, sha)
          open = open_bug_named(bug_name(result.id))
          return [open, disposition(result.id), false] if open

          bug = log(sweep, result, sha)
          bug.triage!(disposition: { value: disposition(result.id) })
          [bug.reference.value, disposition(result.id), true]
        end

        # @return [String] `main-red-<check>`, the name `QaFixMainBug` reads the check back from
        def bug_name(check_id)
          "#{NAME_PREFIX}#{check_id.tr("_", "-")}"
        end

        # @return [String] the bug's disposition as its triage writes it
        def disposition(check_id)
          SELF_CONTAINED.include?(check_id) ? "self_contained" : "bigger"
        end

        private

        def log(sweep, result, sha)
          sequence, reference = next_bug_reference
          ::QualityControl::Bug.log!(
            sweep: sweep.id, reference: { value: reference }, sequence: { value: sequence },
            title: { value: "main is red: #{result.title}" }, name: { value: bug_name(result.id) },
            demonstration: { value: demonstration_text(result) },
            symptom: { value: "the quick gate's #{result.title} exits non-zero on main at #{sha[0, 7]}" },
            expectation: { value: "the quick gate's #{result.title} exits 0 on main" },
            submitter: { value: SUBMITTER }, tags: [{ value: "main-gate" }]
          )
        end

        # @return [String] what the check printed, or a stand-in when it printed nothing
        def demonstration_text(result)
          text = result.output.to_s.strip
          text.empty? ? "(no output)" : text
        end

        def open_bug_named(name)
          row = @runtime.query("QualityControl::Bug.Open").find { |bug| bug[:name]&.[](:value) == name }
          row && row[:reference][:value]
        end

        # @return [Array(Integer, String)] the next sequence and reference, after every logged bug
        def next_bug_reference
          rows = @runtime.query("QualityControl::Bug.All")
          sequence = rows.map { |row| row[:sequence][:value] }.max.to_i + 1
          [sequence, "BUG##{sequence}"]
        end
      end
    end
  end
end
