require "spec_helper"

# S16, ADR 0026 — "THE LANGUAGE USES EVERYTHING IT DECLARES, AND WHAT IT
# DOES NOT USE IS A SUB-LANGUAGE."
#
# Modelled directly on `spec/fuzzing/meta_domain_coverage_spec.rb`'s own
# shape (that file's own header: "requires every declared feature to be
# claimed, guaranteed by construction, structurally exempt, or a named
# gap carrying a one-line reason") — aimed here at a different question:
# not "does a property exist for this attribute," but "does the
# LANGUAGE'S OWN description of itself actually declare an instance of
# this CONSTRUCT KIND," counted the same way ADR 0026's own table was
# measured — "counting real declarations rather than grammar rows."
#
# `entity`/`lifecycle`/`transition` are the two gaps this ADR itself
# names as already closed by the two remodels it commissions (S17, S14)
# — this spec is what makes "closed" a checked fact rather than a claim
# in a commit message. The rest — `policy`/`process_manager`/`ensures`/
# `provenance`/`group_by`/`authorize` — are the ADR's own remaining
# list, ADOPTED where a real, non-decorative use exists (S16 added one:
# `ensures` on `Bluebook.Attach`) and NAMED where it does not — the ADR
# itself warns against the alternative ("Forcing every construct into
# the language... is decoration... modelling to satisfy a tool").
#
# SCOPED TO THE CORE, NOT EVERY ATTACHED SUB-LANGUAGE — the ADR leaves
# this open ("Whether the self-use gate applies to each sub-language
# against its own corpus, or only to the core") and this spec answers
# it: only the core (`LANGUAGE_CHAPTERS` — Bluebook/World/Hecksagon).
# `Paging` contributes grammar ROWS as DATA (`member word: "limit", ...`)
# — it does not itself declare NEW policy/process_manager/entity/etc.
# constructs that would need a self-use claim of their own, and
# extending the gate to every future attached chapter is real, separate
# design work the ADR names as unsettled, not something this slice
# should decide by accident.
#
# CONSTANTS PREFIXED `SELF_USE_` ON PURPOSE — `describe do ... end`'s
# block does not open a new lexical scope for constant assignment the
# way `class`/`module` does, so a bare `LANGUAGE =`/`KNOWN_GAPS =` here
# lands on the top-level Object namespace and silently collides with
# any other spec file's own same-named constant (found for real:
# `spec/orchestration_spec.rb` already declares both).
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

  # ONE COUNTER PER CONSTRUCT — real declarations, the same count ADR
  # 0026's own table measured by hand. `entity`/`lifecycle` count
  # RECURSIVELY (Member nested under ValueObject, Handler under
  # ProcessManager, Dispatch under Handler — S17 — and Keyword/Argument
  # under Syntax — S14 — are real declarations two and three levels
  # down, not just at the aggregate's own top level).
  SELF_USE_COUNTS = {
    "entity"                 => -> { SELF_USE_LANGUAGE.aggregates.sum { |a| count_entities(a) } },
    "lifecycle / transition" => -> {
      SELF_USE_LANGUAGE.aggregates.sum do |a|
        count = a.lifecycle ? 1 : 0
        walk_entities(a) { |e| count += 1 if e.lifecycle }
        count
      end
    },
    "policy"                 => -> { SELF_USE_LANGUAGE.aggregates.sum { |a| a.policies.size } + SELF_USE_LANGUAGE.policies.size },
    "process_manager"        => -> { SELF_USE_LANGUAGE.process_managers.size },
    "ensures"                => -> { every_command.sum { |c| c.ensures.to_a.size } },
    "provenance"             => -> { every_command.count { |c| c.provenance } },
    "group_by"               => -> { SELF_USE_LANGUAGE.read_models.count { |r| !r.group_by.to_a.empty? } },
    "authorize"              => -> { every_query.count(&:authorization) }
  }.freeze

  # NAMED, REASONED — never a silent exclusion. Each entry is the ADR's
  # own prediction ("will fail the day it is written") made permanent
  # and explicit where adoption would be decorative rather than real —
  # the ADR's own "Rejected alternatives" section names exactly this
  # risk for `group_by` ("Paging a grammar... is decoration of exactly
  # the kind ADR 0025 argues against... modelling to satisfy a tool"),
  # and the same reasoning applies to the other three: none of these
  # constructs has a natural, non-invented site in a domain that only
  # ever describes shape, never reacts to time, never involves more
  # than one caller.
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
                         "own records to be walled off by would be pure decoration."
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
                     "the language now declares #{stale.join(', ')} for real — " \
                     "delete the SELF_USE_KNOWN_GAPS entry, the claim is used now"
  end

  it "names no gap for a feature the counters do not track" do
    orphaned = SELF_USE_KNOWN_GAPS.keys - SELF_USE_COUNTS.keys

    expect(orphaned).to be_empty,
                        "SELF_USE_KNOWN_GAPS names #{orphaned.join(', ')}, which SELF_USE_COUNTS does not " \
                        "track — a gap entry for nothing this spec measures is dead weight"
  end
end
