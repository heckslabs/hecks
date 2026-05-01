# Hecks::BluebookModel::Behavior::Mutation
#
# @domain AcceptanceTest
#
# A declarative state change. No Ruby — just field, operation, and value.
# The runtime applies it. The generator transpiles it to any target.
#
#   then_set :status, to: "placed"
#   # => Mutation.new(field: :status, operation: :set, value: "placed")
#
#   then_set :toppings, append: { name: :name, amount: :amount }
#   # => Mutation.new(field: :toppings, operation: :append, value: {...})
#
module Hecks
  module BluebookModel
    module Behavior
      Mutation = Struct.new(:field, :operation, :value, keyword_init: true)
    end
  end
end
