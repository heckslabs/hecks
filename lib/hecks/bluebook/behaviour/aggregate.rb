require_relative "traits"

module Hecks
  module Bluebook
    module Behaviour
      # What an aggregate does, as opposed to what it holds.
      #
      # The holding half — the field list, the readers, the emission — is
      # the same list the language already declares in
      # `language/bluebook/aggregate.bluebook`, said a second and third
      # time in Ruby. This half is not: derived identity, the name
      # indexes, the owner stamping and the finders are decisions about
      # how the declared shape is used, and no grammar states them.
      #
      # Split so the holding half can be generated from the language
      # without any of this being in the blast radius of a regeneration.
      # Everything here is hand-written and permanent.
      #
      # The three traits are shared with Entity (and, for `Indexed`,
      # with Command and PortOperation) — see behaviour/traits.rb on why
      # they are one module rather than four copies.
      module Aggregate
        include Identified
        include Indexed
        include Owns

        # An aggregate is a member of its chapter's namespace — "Pizzas::Pizza" —
        # where everything else is declared on its owner and joins with ".".
        #
        # @return [String] `"::"`, the separator `hecks_fqn` joins this construct's
        #   name onto its owner's with
        def hecks_separator = "::"

        # The hook the generated constructor calls once every declared
        # field is assigned. Nothing here is derivable from the
        # declaration, which is exactly why it is not generated.
        #
        # @return [Bluebook::Aggregate] self, once identity, indexes and ownership stamping
        #   are all derived
        def settle
          derive_identity
          index_declarations
          # An entity stamps its own commands and queries when it is
          # declared, so the chain closes downward from here.
          stamp(@commands, @value_objects, @entities, @queries)
          self
        end

        # Builds every by-name index this aggregate answers finders through.
        #
        # @return [void]
        def index_declarations
          index_attributes(@attributes)
          @value_objects_by_name = index_by_hecks_name(@value_objects)
          @commands_by_name      = index_by_hecks_name(@commands)
          @queries_by_name       = index_by_hecks_name(@queries)
          @ports_by_name         = @ports.to_h { |port| [port.name, port] }
          # S12, ADR 0025 — keyed by symbol, the same convention
          # `Indexed#attribute` already uses; `GuardState` asks for one
          # by name at every dispatch, the rebuild sweep walks all of
          # them once per pass.
          @projected_fields_by_name = @projected_fields.to_h { |field| [field.name, field] }
        end

        # Finds a declared `projects` field by name.
        #
        # @param named [String, Symbol] the projected field's declared name
        # @return [Bluebook::ProjectedField, nil] the field, or `nil` if none is declared
        #   by that name
        def projected_field(named) = @projected_fields_by_name[named.to_sym]

        # A value object is a class now, so `name` is Ruby's answer (the constant
        # path) and the declared name is `hecks_name`. This finder is on its way
        # out — once an attribute's type is the class there is nothing to find —
        # but every consumer still asks by type string, so it stays until they
        # stop.
        #
        # @param named [String, Symbol] the value object's declared type name
        # @return [Bluebook::ValueObject, nil] the value object, or `nil` if none is
        #   declared by that name
        def value_object(named) = @value_objects_by_name[named.to_s]

        # Finds a port declared on this aggregate by name.
        #
        # @param named [String, Symbol] the port's declared name
        # @return [Bluebook::DomainPort, nil] the port, or `nil` if none is declared
        #   by that name
        def port(named)         = @ports_by_name[named.to_s]

        # A port is declared in the hecksagon, not the bluebook — the
        # boundary between the domain and its adapters, in hexagonal terms,
        # is exactly what a `.hecksagon` file already is for every other
        # port (persistence, projection, ...). So this attaches after the
        # aggregate already exists and is registered — `HecksagonBuilder`
        # calls it once per `port` declaration, having already stamped each
        # operation's reference attributes with `declared_in = self`, since
        # nothing upstream of a hecksagon load does that for it.
        #
        # @param port [Bluebook::DomainPort] the operations-shaped port to attach
        # @return [void]
        def add_port(port)
          @ports << port
          @ports_by_name[port.name] = port
        end

        # Names the storage-layer table or collection this aggregate persists to.
        #
        # @return [String] the aggregate's name in `snake_case`
        def storage_name = Naming.snake(@name)
      end
    end
  end
end
