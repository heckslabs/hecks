module Hecksagain
  class Bluebook
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
      module Aggregate
        # An aggregate is a MEMBER of its chapter's namespace — "Pizzas::Pizza" —
        # where everything else is declared ON its owner and joins with ".".
        def hecks_separator = "::"

        # THE HOOK THE GENERATED CONSTRUCTOR CALLS once every declared
        # field is assigned. Three things happen here and none of them
        # are derivable from the declaration:
        def settle
          derive_identity
          index_declarations
          stamp_children
          self
        end

        # THE PATHS, IN DECLARATION ORDER, because the identity IS their join.
        # "number.value" says which field carries the identity ; several paths
        # say the identity is made of several facts, which is what anything
        # named beneath another thing needs. `identity_heads` are the attributes
        # those paths start at — what every reader that looks up or coerces an
        # attribute actually wants — and `identified_by` is the single head,
        # offered ONLY when there is one path to have a head of. A composite has
        # no single head, and answering with the first would be a guess ; the
        # readers that need all of them ask for `identity_heads`.
        def derive_identity
          @identity_paths = Array(@identified_by).map { |path| path.to_s }.reject(&:empty?)
          @identity_heads = @identity_paths.map { |path| path.split(".").first.to_sym }
          @identified_by  = @identity_heads.size == 1 ? @identity_heads.first : nil
        end

        # Indexed once here, since @attributes/@value_objects/@commands/@queries
        # are final by the time an Aggregate exists — every dispatch asks these
        # finders by name, and a linear scan repeated on every call was doing
        # work the declared shape had already settled at boot.
        def index_declarations
          @attributes_by_name    = @attributes.to_h { |a| [a.name, a] }
          @value_objects_by_name = @value_objects.to_h { |shape| [shape.hecks_name, shape] }
          @commands_by_name      = @commands.to_h { |verb| [verb.hecks_name, verb] }
          @queries_by_name       = @queries.to_h { |ask| [ask.hecks_name, ask] }
          @ports_by_name         = @ports.to_h { |port| [port.name, port] }
        end

        # THE AGGREGATE STAMPS ITS OWN CHILDREN. Owner links are only ever
        # read lazily — hecks_fqn at ask time, Reference#resolve at dispatch
        # time — so the constructor is the right stamping point : by the time
        # an Aggregate exists its declarations are final, and nothing outside
        # needs to remember to stamp them. (An entity stamps its own commands
        # and queries when it is declared, so the chain closes downward.)
        def stamp_children
          (@commands + @value_objects + @entities + @queries).each { |child| child.hecks_owner = self }
        end

        def attribute(named)    = @attributes_by_name[named.to_sym]
        # A value object is a CLASS now, so `name` is Ruby's answer (the constant
        # path) and the declared name is `hecks_name`. This finder is on its way
        # out — once an attribute's type IS the class there is nothing to find —
        # but every consumer still asks by type string, so it stays until they
        # stop.
        def value_object(named) = @value_objects_by_name[named.to_s]
        def command(named)      = @commands_by_name[named.to_s]
        # An aggregate answers for its own asks the way it answers for its verbs.
        # An entity has had this finder all along and a head had not, so
        # `QueryInterpreter` hand-rolled the same search — asymmetry, not design.
        def query(named)        = @queries_by_name[named.to_s]
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
