# Naming — the one place a domain name is SPELLED, and the one place a spelled
# name is TAKEN APART.
#
# Commands are declared in the bluebook as the domain says them ("AddTopping")
# and read in Ruby as Ruby says them (`add_topping`). Both spellings are the
# same word, so the conversion lives in exactly one place — the storage name of
# an aggregate and the method name of a command are the same rule.
#
#   Naming.snake("AddTopping")   # => "add_topping"
#   Naming.snake("CreatePizza")  # => "create_pizza"
#   Naming.snake("HTTPGateway")  # => "http_gateway"
#
# The reading half is here for the same reason. `Domain::Aggregate.Command`
# is a grammar, and a grammar read in four places is four parsers that agree
# only by luck — which is the mistake this whole project is about.
#
#   Naming.split_verb("Pizzas::Pizza.Purchase") # => ["Pizzas", "Pizza", "Purchase"]
#   Naming.split_dotted("Account.Opened")       # => ["Account", "Opened"]
#   Naming.qualifier("Account.Opened")          # => "Account"
#
# THIS FILE IS A CROSS-RUNTIME CONTRACT. rust/src/naming.rs mirrors it name
# for name ; spec/naming_spec.rb states the cases both must satisfy.
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

    # ---------------------------------------------------------------------
    # TAKING A NAME APART. The rules above SPELL a name ; these read one that
    # is already spelled. Both live here because they are the same knowledge —
    # what the punctuation in a name means — and knowledge split across files
    # is knowledge that drifts.
    # ---------------------------------------------------------------------

    # A DOTTED NAME, split as written. The same shape carries an entity
    # command (`Line.Amend`), an entity query (`Line.overdue`), and a
    # qualified subscription (`Account.Opened`) — one grammar, so one reader.
    #
    #   split_dotted("Account.Opened") # => ["Account", "Opened"]
    #   split_dotted("Opened")         # => ["Opened", nil]
    #
    # A BARE NAME IS THE FIRST PART, not the second. The two callers read that
    # differently and both are right: an entity path with no dot names an
    # entity and no member, while a subscription with no dot names an event
    # and no qualifier. So the split reports what is WRITTEN and `qualifier`
    # below answers the other question — rather than one function guessing
    # which caller it has.
    def split_dotted(dotted)
      dotted.to_s.split(".", 2)
    end

    # The QUALIFIER of a dotted name, or nil when the name is bare.
    #
    #   qualifier("Account.Opened") # => "Account"
    #   qualifier("Opened")         # => nil
    def qualifier(dotted)
      text = dotted.to_s
      text.include?(".") ? text.split(".", 2).first : nil
    end

    # The NAME with any qualifier stripped — the other half of `qualifier`,
    # and the half a bare name keeps.
    #
    #   unqualified("Account.Opened") # => "Opened"
    #   unqualified("Opened")         # => "Opened"
    def unqualified(dotted)
      dotted.to_s.split(".", 2).last
    end

    # A FULLY-QUALIFIED VERB — `Domain::Aggregate.Command`. Returns the three
    # parts, or nil if the name is not fully qualified. The REFUSAL is the
    # caller's to word, because only the caller knows what it was looking for.
    #
    #   split_verb("Pizzas::Pizza.Purchase") # => ["Pizzas", "Pizza", "Purchase"]
    #   split_verb("Pizza.Purchase")         # => nil
    def split_verb(verb)
      path, command = verb.to_s.split(".", 2)
      domain, aggregate = path.to_s.split("::", 2)
      return nil unless domain && aggregate && command

      [domain, aggregate, command]
    end
  end
end
