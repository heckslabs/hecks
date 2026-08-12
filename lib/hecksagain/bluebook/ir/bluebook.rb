module Hecksagain
  module Bluebook
    module IR
      # A chapter — the top of the construct chain.
      #
      # It is a ROOT: nothing declares it, so `hecks_fqn` is just its name. That is
      # what `hecks_root` exists to say, and saying it here is what keeps
      # `hecks_fqn` refusing for every construct that is merely unstamped.
      class Bluebook
        include Construct
        include Hecksagain::IR

        # THE SCHEMA'S OWN VERSION — not a domain's `version:` (Banking's
        # "v1", a business fact the AUTHOR chose), but the shape `to_h`
        # itself emits. A consumer reading exported IR with no Ruby DSL to
        # cross-check against (a build-time generator, a stored snapshot)
        # needs to know WHICH shape it's holding before it can safely
        # interpret any of the rest of it. Bump this when `to_h`'s own
        # shape changes in a way a consumer would need to know about —
        # not when a domain's own declarations change.
        IR_VERSION = 1

        emits_ir(
          ir_version:       -> { IR_VERSION },
          name:             :name,
          version:          :version,
          vision:           :vision,
          classification:   :classification,
          aggregates:       many(:aggregates),
          read_models:      many(:read_models),
          policies:         many(:policies),
          process_managers: many(:process_managers),
          canonical_form:   -> { Expression::CanonicalForm.table }
        )

        attr_reader :name, :version, :vision, :aggregates, :policies, :process_managers,
                    :classification, :read_models, :ports, :formerly_known_as

        def initialize(name:, version: nil, vision: nil, aggregates: [], policies: [],
                       process_managers: [], classification: nil, read_models: [], formerly_known_as: nil)
          @policies         = policies
          @process_managers = process_managers
          @name       = name.to_s
          @hecks_name = @name
          @hecks_root = true
          @version    = version&.to_s
          @vision     = vision
          @aggregates = aggregates
          @read_models = read_models
          @classification = classification&.to_s
          @formerly_known_as = formerly_known_as&.to_s
          # A port with NO owning aggregate — declared bare at a hecksagon's
          # root, belonging to the chapter as a whole rather than one record.
          # Attached the same way an aggregate-scoped one is, after the fact,
          # from HecksagonBuilder — see IR::Aggregate#add_port's own comment.
          @ports = []
          @ports_by_name = {}

          # THE CHAPTER STAMPS ITS OWN CHILDREN, exactly as an aggregate does.
          # An aggregate's owner is the chapter above it — the way up a
          # Reference#resolve walks — and a read model's is the chapter too,
          # since no single head declares one. A split chapter re-mints its
          # IR::Bluebook per file over the SAME aggregate objects, so the last
          # build's stamping wins — the behaviour the constant tree used to give.
          (@aggregates + @read_models).each { |child| child.hecks_owner = self }
        end

        def aggregate(named) = @aggregates.find { |a| a.name == named.to_s }
        def read_model(named) = @read_models.find { |model| model.name == named.to_s || model.query_name == named.to_s }
        def port(named)      = @ports_by_name[named.to_s]

        def add_port(port)
          @ports << port
          @ports_by_name[port.name] = port
        end

        def verbs
          @aggregates.flat_map do |agg|
            agg.commands.map { |cmd| "#{@name}::#{agg.hecks_name}.#{cmd.hecks_name}" }
          end
        end

      end
    end
  end
end
