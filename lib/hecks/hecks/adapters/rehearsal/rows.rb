# frozen_string_literal: true

module Hecks
  module Adapters
    module Rehearsal
      # The mint audit's refusals as report rows: `Aggregate#id`, the rule that refused, and the
      # audit's own wording, capped, with the total of them all.
      module Rows
        # How many rows a report holds; the total counts the rest.
        CAP = 50

        ROW = /\A([^#:]+)#([^:]+): (.*)\z/m

        module_function

        # @param violations [Array<String>] the audit's refusals, `Aggregate#id: wording`
        # @return [Array(Array<Hash>, Integer)] the first `CAP` rows, and how many there were
        def from(violations)
          [violations.first(CAP).map { |text| row(text) }, violations.size]
        end

        # @param text [String] one refusal
        # @return [Hash] `aggregate`, `id`, `rule`, `wording`
        def row(text)
          match = ROW.match(text)
          aggregate, id, wording = match ? match.captures : ["(edge)", "-", text]
          { aggregate: aggregate, id: id, rule: rule(wording), wording: wording }
        end

        # @param wording [String] a refusal's words
        # @return [String] `lifecycle`, `reference` or `value`
        def rule(wording)
          return "lifecycle" if wording.include?("lifecycle never reaches")
          return "reference" if wording.include?("reference transform") || wording.include?("id set changed")

          "value"
        end
      end
    end
  end
end
