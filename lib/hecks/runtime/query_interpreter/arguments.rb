require_relative "../needs"
require_relative "../value"

module Hecks
  module Runtime
    class QueryInterpreter
      # How a query's arguments are filled and coerced before it runs. Mixed into
      # {QueryInterpreter}.
      module Arguments
        private

        # Coerces a query's arguments exactly as a command's are: a bare scalar of the wrong
        # type refuses with TypeMismatch before any store is read, and so does a nil for a
        # required value-object-typed argument, which would otherwise run an unfiltered query
        # (a Ruby/Rust divergence). The Postgres query builder checks the same shapes
        # (`Value.check_query_arguments!`), so both engines refuse the same way.
        #
        # It does not use `Value::Coercion#nil_argument`, which builds a null value object
        # from field defaults and only refuses when a field has none. `null_vo_argument!`
        # refuses like any other wrong-shaped value. Command arguments are untouched.
        def normalize_args(aggregate, declared, args)
          args = Needs.fill(declared, args, registry: @registry)
          declared.attributes.each_with_object(args.dup) do |attribute, normalized|
            next unless normalized.key?(attribute.name)

            normalized[attribute.name] = coerce_argument(aggregate, attribute, normalized[attribute.name])
          end
        end

        def coerce_argument(aggregate, attribute, value)
          return null_vo_argument!(aggregate, attribute) if checked_vo?(aggregate, attribute, value)

          Value.for_attribute(aggregate, attribute, value)
        end

        def checked_vo?(aggregate, attribute, value)
          return false unless value.nil?
          return false if attribute.optional? || attribute.list? || attribute.reference?
          return false unless aggregate.respond_to?(:value_object)

          !Value.value_object_for(aggregate, attribute.type).nil?
        end

        # Refuses a nil for a value-object argument; never absorbs it via field defaults.
        def null_vo_argument!(aggregate, attribute)
          value_object = Value.value_object_for(aggregate, attribute.type)
          Value.build(value_object, Value.fields_for(value_object, attribute.name, nil), aggregate)
        end
      end
    end
  end
end
