# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "../tools"

module Hecks
  module Tools
    # The names a signed attestation note may carry, read from the rows that declare them: the
    # `GateCheck` rows marked `attests: "yes"` (what the pre-push hook ran green) and the
    # `RequiredCheck` rows' `attests` lists (what CI's own run vouches for). Nothing else names a
    # check a note may stand in for.
    module AttestedChecks
      # Opens a region of a workflow whose `checks:` line the rows write.
      BEGIN_MARKER = "# BEGIN GENERATED attested_checks"

      # Closes it.
      END_MARKER = "# END GENERATED attested_checks"

      # A whole marked region, with the indent its markers share.
      REGION = /^( *)#{Regexp.escape(BEGIN_MARKER)}.*?\n\1#{Regexp.escape(END_MARKER)}$/m

      module_function

      # @return [Array<String>] the ids of the `GateCheck` rows a note may stand in for, in row order
      def local = Hecks::Vocabulary.rows("GateCheck").select { |row| row["attests"] == "yes" }.map { |row| row["id"] }

      # @return [Array<String>] every name CI's note holds: the local checks, then each
      #   `RequiredCheck` row's own names
      def ci = (local + required).uniq

      # @return [Array<String>] the names the `RequiredCheck` rows list
      def required
        Hecks::Vocabulary.rows("RequiredCheck").flat_map { |row| row["attests"].to_s.split(",") }
      end

      # @param stage [String] a `GateStage` name
      # @return [Array<String>] the attestable checks the stage does not run, which a note could
      #   name without the hook having run them
      def unrun_in(stage)
        stage_row = Hecks::Vocabulary.rows("GateStage").find { |row| row["name"] == stage }
        local - stage_row.fetch("checks").split(",")
      end

      # @param text [String] a workflow
      # @return [String] the workflow with every marked region holding the `checks:` line the rows write
      def replace_regions(text) = text.gsub(REGION) { regions_text(Regexp.last_match(1)) }

      # @param indent [String] the spaces the region is indented by
      # @return [String] the region: both markers and the `checks:` line between
      def regions_text(indent)
        ["#{indent}#{BEGIN_MARKER} (GateCheck and RequiredCheck rows; hecks project_ci_gates). Do not hand-edit.",
         "#{indent}checks: #{ci.join(",")}",
         "#{indent}#{END_MARKER}"].join("\n")
      end
    end
  end
end
