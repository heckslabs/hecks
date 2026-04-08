module Hecks
  module Querying
    # Hecks::Querying::ScopeMethods
    #
    # Binds named scope methods onto aggregate classes. Scopes are defined
    # in the domain DSL and represent reusable, named query filters. Each
    # scope becomes a singleton method on the aggregate class that returns
    # a QueryBuilder instance.
    #
    # Scopes can be static (fixed conditions hash) or callable (a lambda
    # that receives arguments and returns a conditions hash).
    #
    # == Usage
    #
    #   # In the domain DSL:
    #   scope :classics, style: "Classic"
    #   scope :priced_above, ->(min) { { price: Operators::Gt.new(min) } }
    #
    #   # After binding:
    #   ScopeMethods.bind(PizzaClass, pizza_aggregate)
    #   Pizza.classics          # => QueryBuilder with where(style: "Classic")
    #   Pizza.priced_above(10)  # => QueryBuilder with where(price: Gt(10))
    #
    module ScopeMethods
        # Binds all scopes from the aggregate definition as class methods.
        #
        # For each scope, defines a singleton method on the aggregate class.
        # If the scope is callable (its conditions respond to +call+), the
        # method accepts arguments that are forwarded to the conditions lambda.
        # Otherwise, the method takes no arguments and uses the static conditions hash.
        #
        # @param klass [Class] the aggregate class to receive scope methods;
        #   must have +@__hecks_repo__+ set (done by AdHocQueries.bind)
        # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
        #   definition containing scope metadata
        # @return [void]
        def self.bind(klass, aggregate)
          aggregate.scopes.each do |scope|
            repo = klass.instance_variable_get(:@__hecks_repo__)
            if scope.callable?
              klass.define_singleton_method(scope.name) do |*args|
                conditions = scope.conditions.call(*args)
                Querying::QueryBuilder.new(repo).where(**conditions)
              end
            else
              klass.define_singleton_method(scope.name) do
                Querying::QueryBuilder.new(repo).where(**scope.conditions)
              end
            end
          end
        end
      end
  end
end
