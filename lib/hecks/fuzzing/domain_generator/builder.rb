require_relative "builder/attribute_shapes"
require_relative "builder/shapes"
require_relative "builder/wiring"

module Hecks
  module Fuzzing
    module DomainGenerator
      # One seeded pass: builds the aggregates the forced forms need, applies
      # each form to the primary aggregate, then sprinkles extras everywhere.
      class Builder
        include AttributeShapes
        include Shapes
        include Wiring

        def initialize(random, forms)
          @random = random
          @forms  = forms
          @names  = AGGREGATE_NAMES.shuffle(random: random)
          @policies = []
        end

        def build
          chain = @forms.intersect?(CHAIN_FORMS)
          aggregates = @names.first(aggregate_count(chain)).map { |name| base(name) }
          primary = aggregates.first

          link_chain(aggregates.first(3)) if chain
          @forms.each { |form| apply_form(form, primary, aggregates) }
          aggregates.each { |aggregate| extras(aggregate, aggregates) }
          { "aggregates" => aggregates, "policies" => @policies }
        end

        FORM_STEPS = {
          "composite_id"       => ->(primary, _) { composite_id(primary) },
          "has_entity"         => ->(primary, _) { entity(primary) },
          "two_entities"       => ->(primary, _) { 2.times { entity(primary) } },
          "composite_piece"    => ->(primary, _) { entity(primary, composite: true) },
          "multi_emit"         => ->(primary, _) { creating(primary)["emits"] << "#{primary["name"]}Logged" },
          "lifecycle"          => ->(primary, _) { lifecycle(primary) },
          "piece_lifecycle"    => ->(primary, _) { entity(primary, lifecycle: true) },
          "has_query"          => ->(primary, _) { query(primary) },
          "list_attr"          => ->(primary, _) { list_attr(primary) },
          "reference_attr"     => ->(primary, all) { reference_attr(primary, all[1]) },
          "closed_set"         => ->(primary, _) { closed_set(primary) },
          "has_default"        => ->(primary, _) { default_attr(primary) },
          "has_optional"       => ->(primary, _) { optional_arg(primary) },
          "two_hop_given"      => ->(primary, all) { two_hop_given(primary, all[1], all[2]) },
          "multi_hop_where"    => ->(primary, all) { multi_hop_where(primary, all[1], all[2]) },
          "revalued_reference" => ->(primary, all) { revalued_reference(primary, all[1]) }
        }.freeze

        private

        # How many aggregates the forms need, with a 30% chance of one more when under three.
        def aggregate_count(chain)
          count = if chain then 3
                  elsif @forms.intersect?(REFERENCE_FORMS) then 2
                  else 1
                  end
          count += 1 if count < 3 && @random.rand < 0.3
          count
        end

        def chance?(probability) = @random.rand < probability

        def base(name)
          aggregate = { "name" => name, "identity" => ["code"], "vos" => {}, "attributes" => [], "references" => [],
                        "lifecycle" => nil, "invariants" => [], "entities" => [], "commands" => [], "queries" => [] }
          vo(aggregate, "#{name}Code", "string")
          aggregate["attributes"] << { "name" => "code", "type" => "#{name}Code" }
          aggregate["commands"] << { "name" => "Open", "creates" => true, "references" => [],
                                     "args" => [{ "name" => "code", "type" => "#{name}Code" }],
                                     "givens" => [], "sets" => [{ "target" => "code" }], "emits" => ["#{name}Opened"] }
          aggregate
        end

        def vo(aggregate, name, kind, members: nil)
          aggregate["vos"][name] ||= { "kind" => kind }.merge(members ? { "members" => members } : {})
        end

        def creating(aggregate) = aggregate["commands"].find { |command| command["creates"] }

        # Adds the command `name` to the aggregate, unless it already has one. `parts` are the
        # command's `args:`, `sets:`, `givens:` (default `[]`) and `emits:` (default: the
        # aggregate's name and the past tense of the verb).
        def command(aggregate, name, **parts)
          existing = aggregate["commands"].find { |candidate| candidate["name"] == name }
          return existing if existing

          entry = { "name" => name, "creates" => false, "references" => [], "args" => parts.fetch(:args, []),
                    "givens" => parts.fetch(:givens, []), "sets" => parts.fetch(:sets, []),
                    "emits" => parts[:emits] || ["#{aggregate["name"]}#{past(name)}"] }
          aggregate["commands"] << entry
          entry
        end

        def past(verb) = verb.end_with?("e") ? "#{verb}d" : "#{verb}ed"

        def apply_form(form, primary, aggregates) = instance_exec(primary, aggregates, &FORM_STEPS.fetch(form))

        def snake(name) = DomainGenerator.snake(name)
      end
    end
  end
end
