module Hecksagain
  module Bluebook
    module DSL
      class BluebookBuilder
        attr_reader :classification

        def initialize(name, version: nil)
          @name       = name
          @version    = version
          @aggregates       = []
          @read_models      = []
          @policies         = []
          @process_managers = []
        end

        def vision(value)
          # moved to the language: Vision invariant, on Chapter.Declare

          @vision = value
        end

        def core       = @classification = :core
        def supporting = @classification = :supporting
        def generic    = @classification = :generic

        def aggregate(name, &block)
          @aggregates << AggregateBuilder.build(name, &block)
        end

        def read_model(name, &block)
          # A read model gathers heads from SEVERAL aggregates, so no single head
          # declares it — the chapter does. Its owner is stamped in `build`, where
          # the chapter namespace exists.
          @read_models << ReadModelBuilder.build(name, &block)
        end

        def policy(name, &block)
          @policies << PolicyBuilder.build(name, &block)
        end

        def process_manager(name, &block)
          @process_managers << ProcessManagerBuilder.build(name, &block)
        end

        def build
          # moved to the language: an attribute type is a reference to its Shape,
          # so an undeclared value object fails reference resolution
          validate_reference_value_objects!
          policies = @aggregates.flat_map(&:policies) + @policies

          # The chapter is the top of the construct chain — `IR::Bluebook` is a
          # ROOT, and its constructor stamps every aggregate and read model with
          # itself as owner, so every `hecks_fqn` below resolves by walking up
          # to it. No constants are installed at load time : the public door is
          # a per-boot projection, installed by `Loader.bind_runtime` once a
          # dispatcher exists to close over (facade/surface.rb).
          bluebook = IR::Bluebook.new(name: @name, version: @version, vision: @vision,
                                      aggregates: @aggregates,
                                      read_models: @read_models,
                                      policies: policies,
                                      process_managers: @process_managers,
                                      classification: @classification)

          # The language judges the bluebook, in the language. Last, so the
          # meta-domain sees a fully built IR — the whole-document rules need
          # every declaration present, which is why they cannot be givens fired
          # at declaration time.
          MetaValidator.call(bluebook)
        end

        private

        # AN ENTITY COMMAND MAY NOT NAME ITSELF AS ITS ROOT.
        #
        # That is the whole of what is left here, and it needs saying plainly
        # because the sentence this used to raise — "references must target
        # aggregate heads" — was never what it checked.
        #
        # `CommandBuilder#reference_to` sets `references` ONLY when the target's
        # bare name equals the owner's ; anything else becomes a reference
        # ATTRIBUTE. So on an aggregate command `references` is always a copy of
        # that aggregate's own name, and looking it up in an index of aggregates
        # is a TAUTOLOGY — that branch never refused anything and structurally
        # could not. Verified across all eight golden chapters before deleting it.
        #
        # On a PIECE's command the owner is the entity, and an entity is not a
        # head, so what this actually refuses is `reference_to <its own name>`
        # written inside `entity do … end`. A piece is reached THROUGH its
        # aggregate ; a command on one addresses the aggregate, never the piece.
        #
        # Reference ATTRIBUTES are the language's business now — offered as the
        # head's own id and resolved as references, so `Aggregate.Reference` and
        # `Command.Reference` refuse an undeclared head with no predicate at all.
        def validate_reference_value_objects!
          heads = @aggregates.map(&:hecks_name)

          violations = @aggregates.flat_map do |aggregate|
            aggregate.entities.flat_map do |entity|
              entity.commands.filter_map do |command|
                next unless command.references
                next if heads.include?(command.references.to_s)

                "#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name} names itself as its root"
              end
            end
          end

          return if violations.empty?

          raise Malformed,
                "an entity command is addressed through its aggregate; #{violations.uniq.join('; ')}"
        end

        # A CHAPTER MAY BE DECLARED IN SEVERAL FILES, meant to merge into ONE
        # domain — `lib/hecksagain/language/bluebook/*.bluebook` all open
        # `Hecks.bluebook "Bluebook" do ... end`. Each `Hecks.bluebook` call used to
        # mint a fresh builder, so a second file with the same chapter name
        # silently replaced the first's aggregates instead of adding to them.
        #
        # The registry now holds the builder OPEN across calls : the first file
        # for a name creates it, every later file for the same name reuses the
        # same instance, so `@aggregates`/`@read_models` accumulate. `#build` is
        # safe to call once per file on the same builder — it constructs a fresh
        # `IR::Bluebook` from whatever is currently held and re-`Namespace.install`s
        # over the previous one, so the LAST file's call leaves every aggregate
        # seen so far reachable, and each call's IR is a strict superset of the
        # one before. `Registry#add_bluebook` still simply stores by name — with
        # this in place, "last write wins" is the cumulative, correct write.
        def self.build(name, version: nil, &block)
          registry = Hecksagain.current_registry
          builder  = registry ? registry.bluebook_builder(name) { new(name, version: version) } : new(name, version: version)
          # A bare constant in a bluebook — `attribute :name, PizzaName` — is a NAME,
          # not a reference to something Ruby has heard of. `const_missing` hands
          # over the symbol, and that is the whole answer: `IR::Attribute` spells it
          # with `to_s`, so the `IR::TypeName` wrapper this used to build existed
          # only long enough to be stringified. The concept still has a home — the
          # language declares `value_object "TypeName"` — it just needed no Ruby
          # class of its own.
          resolver = ->(const) { const }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          builder.build
        end
      end
    end
  end
end
