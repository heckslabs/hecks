# ConstShim — lets a bluebook name a type that does not exist yet.
#
# `attribute :toppings, list_of(Topping)` and `Pizzas::Pizza.persisted_by(...)`
# both reference constants nothing has defined. A DSL block is evaluated with
# the LEXICAL scope of the file it was written in — top level — so a
# const_missing on the builder never fires ; it has to be Object's.
#
# So the hook is installed permanently but stays INERT: with no resolver set it
# is a plain `super`, and normal missing-constant errors behave exactly as they
# should. A loader sets a resolver only for the duration of one load, and always
# restores the previous one.
#
#   ConstShim.with(->(name) { IR::TypeName.new(name) }) { load(path) }
module Hecksagain
  module Language
    module DSL
      module ConstShim
        class << self
          attr_accessor :resolver

          # Install `resolver` for the duration of the block, then put back
          # whatever was there before (nil, normally).
          def with(resolver)
            previous  = @resolver
            @resolver = resolver
            yield
          ensure
            @resolver = previous
          end

          def active? = !@resolver.nil?
        end

        module Hook
          def const_missing(name)
            resolver = ConstShim.resolver
            resolver ? resolver.call(name) : super
          end
        end
      end
    end
  end
end

# Top-level constant lookups route through Object's singleton.
Object.singleton_class.prepend(Hecksagain::Language::DSL::ConstShim::Hook)
