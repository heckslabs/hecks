# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "../tools"

module Hecks
  module Tools
    # The names a signed attestation note may carry, read from the rows that declare them: the
    # `GateCheck` rows marked `attests` (what the pre-push hook ran green) and the `RequiredCheck`
    # rows marked `attests` (what CI's own run vouches for). `CiGates` writes them into the marked
    # regions of the hook and the workflows, so no file keeps a list of its own.
    module AttestedChecks
      # A `RequiredCheck` that sums CI jobs stands in the note under the jobs' names, never its own:
      # one passing leg must not vouch for the whole. The jobs are those of `ci-checks.yml`; when
      # that workflow becomes `CiWorkflows` rows, this mapping moves there.
      JOBS_UNDER = {
        "checks" => %w[checks_fuzz checks_fuzz_postgres checks_fuzz_sqlite checks_codegen_drift]
      }.freeze

      # The files that hold a region: the hook's own line and both note writers of `ci.yml`. Each
      # must have one, or the names it carries were hand-written.
      FILES = [".githooks/pre-push", ".github/workflows/ci.yml"].freeze

      # Opens a region whose one line the rows write; the word after it names the list (`ci` or
      # `local`), and `LINES` gives the line's form.
      BEGIN_MARKER = "# BEGIN GENERATED attested_checks"

      # Closes it.
      END_MARKER = "# END GENERATED attested_checks"

      # A whole marked region, with the indent its markers share and the list it names.
      REGION = /^( *)#{Regexp.escape(BEGIN_MARKER)} (ci|local)\b.*?\n\1#{Regexp.escape(END_MARKER)}$/m

      # The line each list is written as: a workflow's `checks:` input, or the hook's variable.
      LINES = {
        "ci"    => ->(names) { "checks: #{names}" },
        "local" => ->(names) { "ATTEST_CHECKS=\"#{names}\"" }
      }.freeze

      module_function

      # @return [Array<String>] the ids of the `GateCheck` rows a note may stand in for, row order
      def local = Hecks::Vocabulary.rows("GateCheck").select { |row| row["attests"] == "yes" }.map { |row| row["id"] }

      # @return [Array<String>] every name CI's note holds: the local checks, then each marked
      #   `RequiredCheck` row's names
      def ci = (local + required).uniq

      # @return [Array<String>] the names the marked `RequiredCheck` rows stand in under
      def required
        Hecks::Vocabulary.rows("RequiredCheck").select { |row| row["attests"] == "yes" }
                         .flat_map { |row| JOBS_UNDER.fetch(row["name"], [row["name"]]) }
      end

      # @param name [String] `ci` or `local`
      # @return [Array<String>] that list
      def list(name) = name == "ci" ? ci : local

      # @param stage [String] a `GateStage` name
      # @return [Array<String>] the attestable checks the stage does not run, which a note could
      #   name without the hook having run them
      def unrun_in(stage)
        stage_row = Hecks::Vocabulary.rows("GateStage").find { |row| row["name"] == stage }
        local - stage_row.fetch("checks").split(",")
      end

      # @param text [String] a file, as committed
      # @param file [String] its path under the checkout
      # @return [String] the file with every region holding the line the rows write
      # @raise [SystemExit] when a file of `FILES` has no region
      def write(text, file)
        if FILES.include?(file) && !text.match?(REGION)
          abort "ci_gates: #{file} has no BEGIN/END GENERATED attested_checks region"
        end

        text.gsub(REGION) { region(Regexp.last_match(1), Regexp.last_match(2)) }
      end

      # @param indent [String] the spaces the region is indented by
      # @param name [String] the list the region names
      # @return [String] the region: both markers and the line between
      def region(indent, name)
        ["#{indent}#{BEGIN_MARKER} #{name} (GateCheck and RequiredCheck rows; hecks project_ci_gates). Do not hand-edit.",
         "#{indent}#{LINES.fetch(name).call(list(name).join(","))}",
         "#{indent}#{END_MARKER}"].join("\n")
      end
    end
  end
end
