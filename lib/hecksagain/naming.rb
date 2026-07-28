# Naming — the one place a domain name becomes a Ruby name.
#
# Commands are declared in the bluebook as the domain says them ("AddTopping")
# and read in Ruby as Ruby says them (`add_topping`). Both spellings are the
# same word, so the conversion lives in exactly one place — the storage name of
# an aggregate and the method name of a command are the same rule.
#
#   Naming.snake("AddTopping")   # => "add_topping"
#   Naming.snake("CreatePizza")  # => "create_pizza"
#   Naming.snake("HTTPGateway")  # => "http_gateway"
module Hecksagain
  module Naming
    module_function

    # The bare name of a type, whatever arrived: a TypeName from the const
    # shim, or a real class once some domain has claimed that constant.
    #
    #   demodulise("Pizzas::Pizza")  # => "Pizza"
    def demodulise(type)
      type.to_s.split("::").last.to_s
    end

    def snake(text)
      text.to_s
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
    end

    # THE KEY AN AGGREGATE IS ADDRESSED BY, from outside itself — `transfer:`
    # for a Transfer, `atm_card:` for an ATMCard. One idea with three names
    # before this : `reference_key` on the command path (what a
    # `reference_to` lets a caller say), `parent_key` on the query path
    # (whose boundary an element came from), and `own_key` in the saga
    # (whether an event's correlation field names its own emitter). All
    # three open-coded the same transformation, and all three open-coded it
    # WRONG — skipping the acronym rule above, so ATMCard keyed as
    # "atmcard" while its storage_name said "atm_card".
    #
    #   Naming.reference_key("Transfer")        # => :transfer
    #   Naming.reference_key("Banking::ATMCard") # => :atm_card
    def reference_key(type)
      snake(demodulise(type)).to_sym
    end
  end
end
