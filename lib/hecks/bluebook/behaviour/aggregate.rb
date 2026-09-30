require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # What an aggregate does, as opposed to what it holds.
      # Hand-written, so regenerating the declared field list never touches it.
      module Aggregate
        include Identified
        include Indexed
        include Owns

        # An aggregate joins its chapter's namespace with "::" ("Pizzas::Pizza");
        # everything else joins its owner with ".".
        #
        # @return [String] the literal string `"::"`
        def hecks_separator = "::"

        # The hook the generated constructor calls once every declared field is assigned.
        #
        # @return [Bluebook::Aggregate] self, once identity is derived, every
        #   declaration is indexed and its commands, value objects, entities and
        #   queries are stamped as owned by it
        def settle
          derive_identity
          index_declarations
          # An entity stamps its own commands and queries when declared.
          stamp(@commands, @value_objects, @entities, @queries)
          self
        end

        # Builds every by-name finder index `settle` needs — attributes, value
        # objects, commands, queries, ports and projected fields.
        #
        # @return [void]
        def index_declarations
          index_attributes(@attributes)
          @value_objects_by_name = index_by_hecks_name(@value_objects)
          @commands_by_name      = index_by_hecks_name(@commands)
          @queries_by_name       = index_by_hecks_name(@queries)
          @ports_by_name         = @ports.to_h { |port| [port.name, port] }
          # Keyed by symbol, like `Indexed#attribute` (ADR 0025).
          @projected_fields_by_name = @projected_fields.to_h { |field| [field.name, field] }
        end

        # Finds a declared `projects` field by its declared name.
        #
        # @param named [String, Symbol] the projected field's declared name
        # @return [Bluebook::ProjectedField, nil] the field named `named`, or
        #   `nil` if none is declared under that name
        def projected_field(named) = @projected_fields_by_name[named.to_sym]

        # Finds a value object by declared name; `name` on the class is the constant path.
        #
        # @param named [String, Symbol] the value object's declared name
        # @return [Class, nil] the value object class (a `Bluebook::ValueObject`
        #   subclass) named `named`, or `nil` if none is declared under that name
        def value_object(named) = @value_objects_by_name[named.to_s]

        # Finds a port attached to this aggregate by its declared name.
        #
        # @param named [String, Symbol] the port's declared name
        # @return [Bluebook::DomainPort, nil] the port named `named`, or `nil` if
        #   none is attached under that name
        def port(named)         = @ports_by_name[named.to_s]

        # Finds every port whose adapter answers a query.
        #
        # @param named [String, Symbol] the query's declared name
        # @return [Array<Bluebook::DomainPort>] the ports the hecksagon binds to the query; empty
        #   when the query is answered from the aggregate's records
        def query_bindings(named) = @ports.select { |port| port.answer_for(named) }

        # Finds the port whose adapter answers a query.
        #
        # @param named [String, Symbol] the query's declared name
        # @return [Bluebook::DomainPort, nil] the first port bound to the query, or `nil` if
        #   the hecksagon binds none
        def query_binding(named) = query_bindings(named).first

        # Attaches a port declared in the hecksagon, after the aggregate exists.
        # `HecksagonBuilder` stamps each operation's reference attributes with
        # `declared_in = self` before calling it.
        #
        # @param port [Bluebook::DomainPort] the aggregate-scoped port to attach
        # @return [void]
        def add_port(port)
          @ports << port
          @ports_by_name[port.name] = port
        end

        # Names the table, file or key persistence adapters store this aggregate
        # under.
        #
        # @return [String] the aggregate's name, snake-cased
        def storage_name = Naming.snake(@name)
      end
    end
  end
end
