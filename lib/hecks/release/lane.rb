require "hecks/vocabulary"

module Hecks
  module Release
    # The lane a release is cut from, read from the `Lane` rows of the Vocabulary bluebook.
    #
    # A release ships what the gates passed, so it is cut from the guarded lane that feeds a tag
    # (`stable`, which feeds `edge`), never from the lane that takes pushes with no gate.
    module Lane
      module_function

      # @return [String] the name of the lane a release is cut from
      # @raise [KeyError] when no `Lane` row feeds a tag
      def release
        row = Hecks::Vocabulary.rows("Lane").find { |lane| !lane["feeds"].to_s.empty? }
        raise KeyError, "no Lane row feeds a tag, so no lane a release is cut from" unless row

        row.fetch("name")
      end

      # @return [String] the name of the lane a work item's branch is landed onto
      # @raise [KeyError] when no `Lane` row says it lands here
      def lands_here
        row = Hecks::Vocabulary.rows("Lane").find { |lane| lane["lands_here"] == "yes" }
        raise KeyError, "no Lane row says it lands here, so no lane a branch is landed onto" unless row

        row.fetch("name")
      end
    end
  end
end
