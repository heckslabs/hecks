require_relative "traits"

module Hecksagain
  module Bluebook
    module Behaviour
      # WHAT AN AGGREGATE DOES, as opposed to what it holds.
      #
      # The holding half — the field list, the readers, the emission — is
      # the same list the language already declares in
      # `language/bluebook/aggregate.bluebook`, said a second and third
      # time in Ruby. This half is not: derived identity, the name
      # indexes, the owner stamping and the finders are decisions about
      # HOW the declared shape is used, and no grammar states them.
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

        # An aggregate is a MEMBER of its chapter's namespace — "Pizzas::Pizza" —
        # where everything else is declared ON its owner and joins with ".".
        def hecks_separator = "::"

        # THE HOOK THE GENERATED CONSTRUCTOR CALLS once every declared
        # field is assigned. Nothing here is derivable from the
        # declaration, which is exactly why it is not generated.
        def settle
          derive_identity
          index_declarations
          # An entity stamps its own commands and queries when it is
          # declared, so the chain closes downward from here.
          stamp(@commands, @value_objects, @entities, @queries)
          self
        end

        def index_declarations
          index_attributes(@attributes)
          @value_objects_by_name = index_by_hecks_name(@value_objects)
          @commands_by_name      = index_by_hecks_name(@commands)
          @queries_by_name       = index_by_hecks_name(@queries)
          @ports_by_name         = @ports.to_h { |port| [port.name, port] }
          # S12, ADR 0025 — keyed by SYMBOL, the same convention
          # `Indexed#attribute` already uses; `GuardState` asks for one
          # by name at every dispatch, the rebuild sweep walks all of
          # them once per pass.
          @projected_fields_by_name = @projected_fields.to_h { |field| [field.name, field] }
        end

        def projected_field(named) = @projected_fields_by_name[named.to_sym]

        # A value object is a CLASS now, so `name` is Ruby's answer (the constant
        # path) and the declared name is `hecks_name`. This finder is on its way
        # out — once an attribute's type IS the class there is nothing to find —
        # but every consumer still asks by type string, so it stays until they
        # stop.
        def value_object(named) = @value_objects_by_name[named.to_s]
        def port(named)         = @ports_by_name[named.to_s]

        # A PORT IS DECLARED IN THE HECKSAGON, NOT THE BLUEBOOK — the
        # boundary between the domain and its adapters, in hexagonal terms,
        # is exactly what a `.hecksagon` file already IS for every other
        # port (persistence, projection, ...). So this attaches AFTER the
        # aggregate already exists and is registered — `HecksagonBuilder`
        # calls it once per `port` declaration, having already stamped each
        # operation's reference attributes with `declared_in = self`, since
        # nothing upstream of a hecksagon load does that for it.
        def add_port(port)
          @ports << port
          @ports_by_name[port.name] = port
        end

        def storage_name = Naming.snake(@name)
      end
    end
  end
end
