require "hecks/vocabulary"

module Hecks
  module Release
    # The lane a release is cut from, read from the `Lane` rows of the Vocabulary chapter.
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
    end
  end
end
