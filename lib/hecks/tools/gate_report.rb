# frozen_string_literal: true

module Hecks
  module Tools
    # Prints a gate run's verdict: the notes the memo left, the checks it skipped as unchanged, the
    # output and meaning of each red check, and the summary line. A skipped check is printed as
    # skipped, never as passed, and the verdict counts only the checks that ran.
    module GateReport
      module_function

      # @param name [String] the stage name
      # @param plan [GateMemo::Session::Plan] the checks that ran and the ones skipped as unchanged
      # @param results [Hash{String => Array}] each check's output and whether it passed
      # @param notes [Array<String>] what the memo could not record
      # @return [Integer] 0 when every check that ran passed, 1 otherwise
      def report(name, plan, results, notes = [])
        print_notes(name, plan, notes)
        failed = print_failures(name, plan.run, results)
        return summary(name, "red", failed, plan.skipped, 1) unless failed.empty?
        return summary(name, "red", [], [], 1) if proved_nothing?(plan)

        summary(name, "green", plan.run, plan.skipped, 0)
      end

      # Prints the plan's notes and the checks the memo skipped.
      def print_notes(name, plan, notes)
        (plan.notes + notes).each { |note| puts "[gate #{name}] #{note}" }
        plan.skipped.each { |check, since| print_skipped(name, check, since) }
      end

      # A stage with no check that ran or was recorded green has proved nothing, so it is not green.
      # @return [Boolean] whether the plan leaves no check to stand behind a green verdict
      def proved_nothing?(plan) = plan.run.empty? && plan.skipped.empty?

      # @return [Array<Hash>] the checks that did not pass, after printing each one's output and
      # meaning
      def print_failures(name, checks, results)
        checks.reject { |check| results.fetch(check["id"]).last }.each do |check|
          print_failure(name, check, results.fetch(check["id"]).first)
        end
      end

      # @return [void] prints a check the memo skipped, as skipped and never as passed
      def print_skipped(name, check, since)
        puts "[gate #{name}] #{check["id"]}: unchanged, skipped (green as of #{since})"
      end

      # @return [Integer] the given status, after printing the stage's verdict, the checks that ran
      # and
      #   the checks skipped as unchanged
      def summary(name, verdict, checks, skipped, status)
        ran = checks.map { |check| check["id"] }
        line = "[gate #{name}] #{verdict}: #{ran.empty? ? "nothing ran" : ran.join(", ")}"
        line += "; skipped as unchanged: #{skipped.map { |check, _| check["id"] }.join(", ")}" if skipped.any?
        puts line
        status
      end

      # @return [void] prints a failing check's output and what its failure means
      def print_failure(name, check, output)
        puts "\n[gate #{name}] #{check["title"]}\n\n#{output}"
        puts "\n[gate #{name}] BLOCKED: #{check["blocked"]}\n"
      end
    end
  end
end
