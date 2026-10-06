# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module DeployRecipeLint
      # The three recipe checks, each answering the violations it finds in one target.
      module Checks
        # Flags a chain that runs an AWS/DB command and later hits an unconditional `exit 0`.
        def check_blind_exit_zero(target, chains)
          chains.filter_map { |chain| blind_exit_zero(target, chain) }
        end

        # Flags `exit $?` whose preceding statement in the chain is a benign echo/no-op.
        def check_stale_dollar_question(target, chains)
          chains.filter_map { |chain| stale_dollar_question(target, chain) }
        end

        # Flags a target whose first AWS/DB command has no earlier echo step.
        def check_prod_touch_without_echo(target, recipe_lines)
          ordered = real_statements(recipe_lines)
          first_risky = ordered.find { |_, text| RISKY_REGEX.match?(text) }
          return [] if first_risky.nil? || echo_before?(ordered, first_risky)

          [Violation.new(
            target: target, line: first_risky.first + 1, rule: "PROD_TOUCH_WITHOUT_ECHO",
            message: "touches AWS/DB (#{first_risky.last.strip.inspect}) with no earlier echo/validation step in this " \
                     "recipe naming what it's about to do to a human running it interactively."
          )]
        end

        private

        def blind_exit_zero(target, chain)
          exit_zero = chain.find { |_, stmt| BARE_EXIT_ZERO_REGEX.match?(normalize_statement(stmt)) }
          return unless exit_zero

          risky_before = chain.take_while { |line_no, _| line_no != exit_zero.first }
                              .select { |_, stmt| RISKY_REGEX.match?(stmt) }
          return if risky_before.empty?

          Violation.new(target: target, line: exit_zero.first + 1, rule: "UNVERIFIED_EXIT_ZERO",
                        message: blind_exit_message(risky_before.last))
        end

        def blind_exit_message(risky)
          "unconditional `exit 0` follows an AWS/DB-touching command (line #{risky.first + 1}: " \
            "#{risky.last.strip.inspect}) whose own exit status this chain never checks — a real " \
            "failure there would still report success."
        end

        def stale_dollar_question(target, chain)
          idx = chain.index { |_, stmt| DOLLAR_QUESTION_EXIT_REGEX.match?(normalize_statement(stmt)) }
          return unless idx

          prev = idx.positive? ? chain[idx - 1] : nil
          return unless prev && BENIGN_REGEX.match?(normalize_statement(prev.last))

          Violation.new(target: target, line: chain[idx].first + 1, rule: "STALE_DOLLAR_QUESTION",
                        message: stale_question_message(prev))
        end

        def stale_question_message(prev)
          "`exit $?` follows a benign statement (line #{prev.first + 1}: #{prev.last.strip.inspect}), " \
            "not the meaningful command it claims to report on — capture the real command's status into a " \
            "named variable instead (this codebase's own convention, e.g. `BOOT_STATUS=$$?` ... " \
            "`exit $$BOOT_STATUS`) and exit that, not a bare $?."
        end

        def echo_before?(ordered, first_risky)
          ordered.take_while { |line_no, _| line_no != first_risky.first }
                 .any? { |_, text| ECHO_REGEX.match?(text) }
        end
      end
    end
  end
end
