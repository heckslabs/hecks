module Hecksagain
  module Bluebook
    module IR
      class Aggregate
        # A construct like every other: the aggregate carries its own identity
        # and sits in the owner chain between its chapter (an IR::Bluebook) and
        # everything declared on it. The chain is IR objects end to end now —
        # reference resolution and hecks_fqn both walk it, and neither needs a
        # Ruby class to exist.
        include Construct
        include Hecksagain::IR

        emits_ir(
          name:          :name,
          description:   :description,
          identified_by: :identity_paths,
          attributes:    many(:attributes),
          value_objects: many(:value_objects),
          commands:      many(:commands),
          lifecycle:     one(:lifecycle),
          entities:      many(:entities),
          queries:       many(:queries),
          # ADDITIVE — every domain that declares no port emits `ports: []`,
          # the same "regenerate deliberately" wire-format change
          # ir_golden_spec.rb's own header describes; no existing key
          # moves. See docs/decisions (rust/project/ports.rb) for the
          # first reader of this.
          ports:         many(:ports),
          provenance:    :provenance
        )

        attr_reader :name, :description, :attributes, :value_objects, :commands,
                    :identified_by, :identity_paths, :identity_heads, :lifecycle,
                    :entities, :queries, :policies, :ports, :reference_targets, :provenance

        # An aggregate is a MEMBER of its chapter's namespace — "Pizzas::Pizza" —
        # where everything else is declared ON its owner and joins with ".".
        def hecks_separator = "::"

        def initialize(name:, description: nil, attributes: [], value_objects: [],
                       commands: [], identified_by: [], lifecycle: nil,
                       entities: [], queries: [], policies: [], ports: [], reference_targets: [],
                       provenance: nil)
          @entities      = entities
          @queries       = queries
          @policies      = policies
          @ports         = ports
          @name          = name.to_s
          @hecks_name    = @name
          @description   = description
          @attributes    = attributes
          @value_objects = value_objects
          @commands      = commands
          # THE PATHS, IN DECLARATION ORDER, because the identity IS their join.
          # "number.value" says which field carries the identity ; several paths
          # say the identity is made of several facts, which is what anything
          # named beneath another thing needs. `identity_heads` are the attributes
          # those paths start at — what every reader that looks up or coerces an
          # attribute actually wants — and `identified_by` is the single head,
          # offered ONLY when there is one path to have a head of. A composite has
          # no single head, and answering with the first would be a guess ; the
          # readers that need all of them ask for `identity_heads`.
          @identity_paths = Array(identified_by).map { |path| path.to_s }.reject(&:empty?)
          @identity_heads = @identity_paths.map { |path| path.split(".").first.to_sym }
          @identified_by  = @identity_heads.size == 1 ? @identity_heads.first : nil
          @lifecycle     = lifecycle
          @reference_targets = reference_targets
          @provenance    = provenance

          # Indexed once here, since @attributes/@value_objects/@commands/@queries
          # are final by the time an Aggregate exists — every dispatch asks these
          # finders by name, and a linear scan repeated on every call was doing
          # work the declared shape had already settled at boot.
          @attributes_by_name    = @attributes.to_h { |a| [a.name, a] }
          @value_objects_by_name = @value_objects.to_h { |shape| [shape.hecks_name, shape] }
          @commands_by_name      = @commands.to_h { |verb| [verb.hecks_name, verb] }
          @queries_by_name       = @queries.to_h { |ask| [ask.hecks_name, ask] }
          @ports_by_name         = @ports.to_h { |port| [port.name, port] }

          # THE AGGREGATE STAMPS ITS OWN CHILDREN. Owner links are only ever
          # read lazily — hecks_fqn at ask time, Reference#resolve at dispatch
          # time — so the constructor is the right stamping point : by the time
          # an Aggregate exists its declarations are final, and nothing outside
          # needs to remember to stamp them. (An entity stamps its own commands
          # and queries when it is declared, so the chain closes downward.)
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
        def port(named)          = @ports_by_name[named.to_s]

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
