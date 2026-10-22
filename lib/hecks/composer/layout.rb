module Hecks
  module Composer
    # Proposes which panels the editor shows beside the text, on the hecksagon side like the
    # other composer files. It is a small rule set, not a model call: the same inputs always give
    # the same answer, and it reads only the author's intent and the check's verdict.
    module Layout
      module_function

      # @param intent [String] "edit", "wire", "question" or "new_domain"
      # @param check [Hash] the result of {Check.call}
      # @param changed [Hash] the files the last request changed, by path
      # @return [Hash] `right` (one of the panel names) and `bottom` (always "agent")
      def propose(intent:, check:, changed:)
        { right: right(intent, check, changed), bottom: "agent" }
      end

      # A refusal or an error finding comes first; then the author's intent decides.
      # @api private
      def right(intent, check, _changed)
        return "findings" if refused?(check)

        case intent
        when "wire" then "wiring"
        when "question" then "statements"
        else "diagram"
        end
      end

      # @api private
      def refused?(check)
        return true if check[:diagnostic]

        Array(check[:findings]).any? { |finding| finding[:severity].to_s == "error" }
      end
    end
  end
end
