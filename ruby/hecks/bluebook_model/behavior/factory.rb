# [antibody-exempt: ruby/hecks/bluebook_model/behavior/factory.rb —
#  kernel-floor IR node : Behavior::Factory is the Ruby mirror of the Rust
#  Factory node (first-class factories phase 1, locked design
#  docs/designs/first-class-factories.md). Retires when the Ruby mirror is
#  generated from the grammar bluebooks.]
module Hecks
  module BluebookModel
    module Behavior

      # Hecks::BluebookModel::Behavior::Factory
      #
      # A BIRTH — mints a new aggregate instance, error if the id already
      # exists. First-class sibling to Command (2026-06-12 locked design,
      # docs/designs/first-class-factories.md) : a Command transitions an
      # EXISTING instance ; a Factory creates one. Declared with the
      # `factory "Name"[, produces: Other] do … end` DSL keyword inside
      # the aggregate that OWNS creation — which, per Evans, is not
      # necessarily the aggregate being created (`produces:` names the
      # cross-aggregate target ; nil births the enclosing aggregate).
      #
      # Plain data object (IR node). Built by AggregateBuilder#factory
      # (the body grammar is identical to a command's, so CommandBuilder
      # reads the block and the result is lifted into a Factory).
      # Supersedes the transient Command#creates bool (#729).
      #
      #   factory "Plan" do                    # births a Sprint (enclosing)
      #     attribute :number, SprintNumber
      #     given { number.positive? }         # creation invariant, at birth
      #     emits "SprintPlanned"
      #   end
      #
      #   factory "DraftStory", produces: Story do  # Backlog drafts Story
      #     attribute :title, Title
      #     emits "StoryDrafted"
      #   end
      class Factory
        attr_reader :name, :produces, :attributes, :references,
                    :actors, :emits, :emits_identified_by,
                    :description, :goal,
                    :givens, :mutations

        # @param name [String] PascalCase factory name (e.g. "Plan")
        # @param produces [String, nil] aggregate this factory births ;
        #   nil = the enclosing aggregate (the default, self case)
        def initialize(name:, produces: nil, attributes: [], references: [],
                       actors: [], emits: nil, emits_identified_by: nil,
                       description: nil, goal: nil,
                       givens: [], mutations: [])
          @name = Names.command_name(name)
          @produces = produces
          @attributes = attributes
          @references = references
          @actors = actors
          @emits = emits
          @emits_identified_by = emits_identified_by
          @description = description
          @goal = goal
          @givens = givens
          @mutations = mutations
        end

        # Lift a parsed Command into a Factory — the DSL body grammar is
        # identical, so AggregateBuilder reads the block via CommandBuilder
        # and converts. Mirrors rust parse_factory's delegation.
        #
        # @param cmd [Behavior::Command] the parsed body
        # @param produces [String, nil] the produces: kwarg, if any
        # @return [Factory]
        def self.from_command(cmd, produces: nil)
          new(
            name: cmd.name,
            produces: produces,
            attributes: cmd.attributes,
            references: cmd.references,
            actors: cmd.actors,
            emits: cmd.emits,
            emits_identified_by: cmd.emits_identified_by,
            description: cmd.description,
            goal: cmd.goal,
            givens: cmd.givens,
            mutations: cmd.mutations,
          )
        end
      end
    end
  end
end
