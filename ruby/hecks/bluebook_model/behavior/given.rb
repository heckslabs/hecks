# Hecks::BluebookModel::Behavior::Given
#
# @domain AcceptanceTest
#
# A precondition expressed in the ubiquitous language. Pure declaration —
# no Ruby Proc. The expression is a string that can be interpreted at
# runtime or transpiled to any target language.
#
#   given { toppings.size < 10 }
#   # => Given.new(expression: "toppings.size < 10")
#
module Hecks
  module BluebookModel
    module Behavior
      Given = Struct.new(:expression, :message, keyword_init: true)
    end
  end
end
