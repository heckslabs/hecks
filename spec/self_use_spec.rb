require "spec_helper"

# S16, ADR 0026: the core language's own description must declare at least one instance of
# each construct kind, or name the gap with a reason. Scoped to the core chapters
# (`LANGUAGE_CHAPTERS`), not every attached sub-language.
#
# Constants are prefixed `SELF_USE_`: a describe block does not open a lexical scope, so bare
# names land on `Object` and collide with other spec files.
RSpec.describe "the language uses everything the core grammar declares" do
  SELF_USE_LANGUAGE = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.walk_entities(node, &block)
    node.entities.each do |entity|
      block.call(entity)
      walk_entities(entity, &block)
    end
  end

  def self.count_entities(node)
    node.entities.sum { |entity| 1 + count_entities(entity) }
  end

  def self.every_command
    SELF_USE_LANGUAGE.aggregates.flat_map do |aggregate|
      commands = aggregate.commands.dup
      walk_entities(aggregate) { |entity| commands.concat(entity.commands) }
      commands
    end
  end

  def self.every_query
    SELF_USE_LANGUAGE.aggregates.flat_map do |aggregate|
      queries = aggregate.queries.dup
      walk_entities(aggregate) { |entity| queries.concat(entity.queries) }
      queries
    end
  end

  # One counter per construct, counting real declarations. `entity`/`lifecycle` count
  # recursively, since nested entities are real declarations too.
  SELF_USE_COUNTS = {
    "entity"                 => -> { SELF_USE_LANGUAGE.aggregates.sum { |a| count_entities(a) } },
    "lifecycle / transition" => lambda {
      SELF_USE_LANGUAGE.aggregates.sum do |a|
        count = a.lifecycle ? 1 : 0
        walk_entities(a) { |e| count += 1 if e.lifecycle }
        count
      end
    },
    "policy"                 => -> { SELF_USE_LANGUAGE.aggregates.sum { |a| a.policies.size } + SELF_USE_LANGUAGE.policies.size },
    "process_manager"        => -> { SELF_USE_LANGUAGE.process_managers.size },
    "ensures"                => -> { every_command.sum { |c| c.ensures.to_a.size } },
    "provenance"             => -> { every_command.count(&:provenance) },
    "group_by"               => -> { SELF_USE_LANGUAGE.read_models.count { |r| !r.group_by.to_a.empty? } },
    "authorize"              => -> { every_query.count(&:authorization) },
    # The language classifies itself `core`, never `generic` (a candidate for demotion,
    # ADR 0026), so this counts real self-classification, not a grammar row.
    "generic"                => -> { SELF_USE_LANGUAGE.classification == "generic" ? 1 : 0 }
  }.freeze

  # Named gaps, never silent exclusions: adopting these constructs in a domain that only
  # describes shape would be decoration, not real use (ADR 0026).
  SELF_USE_KNOWN_GAPS = {
    "policy"          =>
                         "a policy reacts to an event with a trigger and (optionally) a with: " \
                         "projection — the language's own commands each mint one static record " \
                         "and react to nothing; inventing a reaction among them would be a " \
                         "policy in name only, satisfying the gate rather than describing a " \
                         "real cross-command consequence.",
    "process_manager" =>
                         "a saga correlates several commands over time via the events they " \
                         "emit — nothing in the language's own description is a multi-step " \
                         "workflow; every declaration here is a single, complete, one-shot " \
                         "fact about a construct, with no \"and then\" for a saga to carry.",
    "provenance"      =>
                         "provenance records where a construct's SHAPE was ported from " \
                         "(banking's own use: \"HecksCanonical\", an external canonical " \
                         "model) — the language's own aggregates ARE the canonical " \
                         "definition, not a port of one; naming a source for something " \
                         "that has none would be fiction, not documentation.",
    "group_by"        =>
                         "the ADR's own \"Rejected alternatives\" names this exact risk " \
                         "(\"grouping words by context... is decoration... modelling to " \
                         "satisfy a tool\") for the read model this gate would have to " \
                         "invent — WholeBluebook already gathers everything a chapter holds " \
                         "in one read, and no real question the language needs answered " \
                         "about itself is a REDUCTION over its own records rather than the " \
                         "records themselves.",
    "authorize"       =>
                         "authorize gates a query behind a tenant/policy boundary — the " \
                         "language has no multi-tenant concept of its own; a grammar row is " \
                         "not scoped to a caller, and inventing a tenant for the language's " \
                         "own records to be walled off by would be pure decoration.",
    "generic"         =>
                         "generic marks a bluebook as NOT a real business domain, so that " \
                         "Expression/Translation/Paging can classify themselves that way — " \
                         "the language's own chapter IS the canonical grammar, declared " \
                         "`core`, and applying `generic` reflexively to the definition that " \
                         "does the classifying would be the sub-language demotion test " \
                         "turned on itself. ADR 0025 already names it as zero-corpus-use " \
                         "everywhere, not just here; ADR 0026's own Consequences section " \
                         "names this exact gap by hand."
  }.freeze

  it "uses every construct it declares, or names why not" do
    unnamed = SELF_USE_COUNTS.reject { |feature, counter| counter.call.positive? || SELF_USE_KNOWN_GAPS.key?(feature) }

    expect(unnamed).to be_empty, <<~WHY
      These constructs are declared by the core grammar and never
      DECLARED FOR REAL anywhere in the language's own chapters — only
      grammar rows describing what they look like, never an instance of
      one:

        #{unnamed.keys.join("\n        ")}

      Either use the construct for real somewhere in
      lib/hecks/language/bluebook/, or name it in SELF_USE_KNOWN_GAPS
      with a reason it cannot be, honestly.
    WHY
  end

  it "measures a real use it is known to have" do
    used = SELF_USE_COUNTS.reject { |feature, _| SELF_USE_KNOWN_GAPS.key?(feature) }

    expect(used).not_to be_empty, "every feature is a named gap — nothing is claimed as used, which is " \
                                  "suspicious enough on its own to be worth a second look"
  end

  it "carries no gap the language has outgrown" do
    stale = SELF_USE_KNOWN_GAPS.keys.select { |feature| SELF_USE_COUNTS.fetch(feature).call.positive? }

    expect(stale).to be_empty,
                     "the language now declares #{stale.join(", ")} for real — " \
                     "delete the SELF_USE_KNOWN_GAPS entry, the claim is used now"
  end

  it "names no gap for a feature the counters do not track" do
    orphaned = SELF_USE_KNOWN_GAPS.keys - SELF_USE_COUNTS.keys

    expect(orphaned).to be_empty,
                        "SELF_USE_KNOWN_GAPS names #{orphaned.join(", ")}, which SELF_USE_COUNTS does not " \
                        "track — a gap entry for nothing this spec measures is dead weight"
  end
end
