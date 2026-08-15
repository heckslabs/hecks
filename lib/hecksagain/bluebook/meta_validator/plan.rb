module Hecksagain
  module Bluebook
    module MetaValidator
      # What the language says about ITSELF, read back as something walkable.
      #
      # The judge used to carry one hand-written branch per category, and the
      # reason given for keeping it that way was that "which append command
      # belongs to which list is not derivable from a name". True — and beside
      # the point. It is derivable from the language's own IR, because every
      # append command DECLARES its target:
      #
      #     command "Argument" do
      #       reference_to Command
      #       then_set :arguments, append: { name: :name, type: :type, ... }
      #     end
      #
      # That one line says both things a walk needs: `Command.Argument` is the
      # appender for the `arguments` list, and the map binds each value-object
      # field to the command argument that fills it. Nothing is matched by name.
      #
      # The same reading recovers the containment tree. A command with NO
      # self-reference is the creating one, and the `*_id` argument it carries
      # names the parent — so Bluebook -> Aggregate -> Command / ValueObject /
      # Query / Entity, ValueObject -> Member, ProcessManager -> Handler ->
      # Dispatch all fall out of the declarations rather than being restated here.
      #
      # Usage:
      #
      #     plan = Plan.for(MetaValidator.grammar_registry)
      #     plan.category("Command").parent            # => "Aggregate"
      #     plan.category("Command").appends["rules"]  # => Append(verb: "Rule", map: {...})
      #     plan.verbs                                 # every Bluebook:: verb declared
      #
      # This reads the language. It does not read a bluebook and it dispatches
      # nothing — that is the judge's job.
      class Plan
        # One append command: the verb, and the value-object-field -> argument map.
        Append = Struct.new(:verb, :map, keyword_init: true)

        # One setting command. `targets` is target -> argument ; Lifecycle sets two
        # fields in a single command, so it is a map rather than a pair.
        Setter = Struct.new(:verb, :targets, keyword_init: true)

        Category = Struct.new(:name, :declare, :parent, :parent_key, :fields,
                              :appends, :alternates, :setters, :sealers, :references,
                              :identity_paths,
                              keyword_init: true) do
          # Every verb this category declares, in declaration order. `alternates`
          # matters here: two commands can append to one list, and a verb missing
          # from this is a verb the coverage gate stops watching.
          def verbs
            [declare, *setters.map(&:verb), *appends.values.map(&:verb),
             *alternates.map(&:verb), *sealers].compact
          end

          # DOES THIS ARGUMENT CARRY AN ID? A reference is the id of a head, and
          # an id is a scalar — so the judge offers it bare, where every other
          # field goes as a one-field value object. The language answers this
          # about itself, so declaring a new reference needs no change here.
          def references?(verb, argument)
            Array(references[verb.to_s]).include?(argument.to_s)
          end

          def root? = parent.nil?
        end

        def self.for(registry)
          new(registry.bluebook("Bluebook"))
        end

        attr_reader :categories

        def initialize(meta)
          @categories = meta.aggregates.each_with_object({}) do |aggregate, plan|
            # Vocabulary declares no commands — it is static declaration read from
            # the IR by spec/vocabulary_conformance_spec, never dispatched. It needs
            # no special case: a category with nothing to offer contributes nothing.
            next if aggregate.commands.empty?

            plan[aggregate.hecks_name] = read(aggregate)
          end.freeze
        end

        def category(name) = @categories[name.to_s]
        def names          = @categories.keys

        # Every verb the language declares, spelled as the judge would dispatch it.
        def verbs
          @categories.flat_map { |name, category| category.verbs.map { |verb| "Bluebook::#{name}.#{verb}" } }
        end

        private

        def read(aggregate)
          declare    = creating_command(aggregate)
          parent     = parent_reference_of(declare)
          parent_key = parent&.name&.to_s
          rest       = aggregate.commands - [declare].compact

          Category.new(
            name:       aggregate.hecks_name,
            declare:    declare&.hecks_name,
            parent:     parent&.type&.target_name,
            parent_key: parent_key,
            fields:     declared_fields(declare),
            appends:    appends_in(rest),
            alternates: alternates_in(rest),
            setters:    setters_in(rest),
            sealers:    sealers_in(rest),
            # EVERY command, not `rest` — the creating command carries the parent
            # link, which is the most common reference of all.
            references: references_in(aggregate.commands),
            # HOW THE CATEGORY NAMES ITS RECORDS, read from the language rather
            # than restated. The judge has to know a record's id BEFORE it
            # dispatches, because the children it walks next carry it as their
            # parent — so it derives the same join the runtime will, off the same
            # declaration. It used to be a branch per category, and a branch that
            # disagreed with the runtime by one separator was a broken reference.
            identity_paths: aggregate.identity_paths
          )
        end

        # Which arguments of which verbs carry an ID rather than a value, read
        # straight from the language's own IR.
        def references_in(commands)
          commands.each_with_object({}) do |command, found|
            named = command.attributes.select(&:reference?).map { |attribute| attribute.name.to_s }
            found[command.hecks_name] = named unless named.empty?
          end
        end

        # The creating command is the one that does not reach through its own root.
        # `references` only ever holds a SELF reference — CommandBuilder turns any
        # other target into a Reference<X> attribute — so this is the same test the
        # runtime makes with `creates?`, read off the language instead of the code.
        def creating_command(aggregate)
          aggregate.commands.find { |command| command.references.nil? }
        end

        # The parent link is the creating command's FIRST reference-typed
        # argument, left there by `reference_to Parent`. Declaration
        # ORDER is what this always actually relied on — ADR 0025
        # dropped the `_id` suffix that used to also flag it, but that
        # suffix never carried the real signal; `reference_to`'s own
        # attribute order does, and always did (the parent link is
        # declared first, before any other reference a command takes).
        # A category without one is a root (Bluebook).
        def parent_reference_of(declare)
          return nil unless declare

          declare.attributes.find(&:reference?)
        end

        # What the creating command sets directly. EVERY reference
        # argument is dropped, not just the parent link: a reference is
        # not a field. Command.Declare carries `entity_id` as well as
        # the parent `aggregate` reference, because an entity declares
        # commands too, and offering either as a field would have the
        # walk hand it a name instead of a head.
        def declared_fields(declare)
          return [] unless declare

          declare.attributes.reject(&:reference?).map { |attribute| attribute.name.to_s }
        end

        # list attribute -> the command that appends to it, and how its arguments map.
        def appends_in(commands)
          commands.each_with_object({}) do |command, found|
            Array(command.mutations).each do |mutation|
              next unless mutation.op == :append

              # FIRST wins, not last. Two commands can append to the same list —
              # Aggregate.Attribute and Aggregate.Reference both extend `attributes`,
              # because a reference's type is not a value object and cannot go
              # through the same verb. Overwriting would have let the one declared
              # later silently displace the other, and the walk would have offered
              # every ordinary attribute as a reference.
              found[mutation.target.to_s] ||= Append.new(verb: command.hecks_name, map: mutation.source)
            end
          end
        end

        # The appenders DISPLACED by first-wins — Aggregate.Reference behind
        # Aggregate.Attribute. The walk reaches them by reading the row, not the
        # plan, but they are still verbs the language declares and the coverage
        # gate has to see them.
        def alternates_in(commands)
          claimed = {}
          commands.flat_map do |command|
            Array(command.mutations).filter_map do |mutation|
              next unless mutation.op == :append

              target = mutation.target.to_s
              if claimed[target]
                Append.new(verb: command.hecks_name, map: mutation.source)
              else
                claimed[target] = true
                nil
              end
            end
          end
        end

        # Commands that SET rather than append. Lifecycle sets two targets at once,
        # so a setter is keyed by its verb and carries every target it writes.
        def setters_in(commands)
          commands.filter_map do |command|
            targets = Array(command.mutations)
                      .select { |mutation| mutation.op == :set }
                      .to_h { |mutation| [mutation.target.to_s, mutation.source.to_s] }
            next if targets.empty?

            Setter.new(verb: command.hecks_name, targets: targets)
          end
        end

        # Commands that change nothing — they exist to be REFUSED. Aggregate.Seal is
        # the whole-document check: dispatched once everything is declared, carrying
        # only givens. A category with no sealer simply has no such rule.
        def sealers_in(commands)
          commands.select { |command| Array(command.mutations).empty? }.map(&:hecks_name)
        end
      end
    end
  end
end
