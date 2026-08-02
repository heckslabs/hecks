module Hecksagain
  module Bluebook
    # The expression language a bluebook's predicates are written in —
    # canonicalised (canonical_form), resolved against a chapter's names
    # (resolver), and evaluated (evaluator).
    module Expression
    end
  end
end

require_relative "expression/canonical_form"
require_relative "expression/resolver"
require_relative "expression/evaluator"
