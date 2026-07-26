# BindingProxy — makes `Pizzas::Pizza.persisted_by("Sqlite")` a legal sentence.
#
# Neither Pizzas nor Pizza exists as a Ruby constant when the hecksagon loads,
# and `A::B` demands that A be a real Module — so the const_missing resolver
# hands back a NAMESPACE module whose own const_missing yields one of these
# proxies. The proxy then accepts ANY how-verb by method_missing, because the
# verb vocabulary belongs to the families, not to this class:
#
#   Pizzas   → namespace module
#   ::Pizza  → BindingProxy("Pizzas::Pizza")
#   .persisted_by("Sqlite") → Bind(aggregate:, verb:, adapter:)
#
# Adding a family never requires touching this file. That is the point.
module Hecksagain
  module Language
    module DSL
      class BindingProxy
        # Builds the namespace module a bare domain constant resolves to.
        def self.namespace(domain, collector)
          Module.new do
            define_singleton_method(:const_missing) do |aggregate|
              BindingProxy.new("#{domain}::#{aggregate}", collector)
            end
          end
        end

        def initialize(fqn, collector)
          @fqn       = fqn
          @collector = collector
        end

        # Any verb at all — the family declares which ones are real, and the
        # attach check verifies it at boot.
        def method_missing(verb, *args, **_kwargs, &block)
          @collector << IR::Bind.new(aggregate: @fqn, verb: verb.to_s, adapter: args.first.to_s)
          block&.call
          self
        end

        def respond_to_missing?(_name, _include_private = false) = true

        def to_s = @fqn
      end
    end
  end
end
