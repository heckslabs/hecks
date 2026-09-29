require "spec_helper"
require "hecks/doc/reference"

# A doctest alone can pass on a page's own invented fixture (ADR 0025); this
# checks that a live word also has a real corpus declaration, or a named exemption.
RSpec.describe "every live DSL word, used somewhere real" do
  # Widened from spec/corpus_spec.rb's own CORPUS_MEMBERS walk to every
  # extension a real domain ships (`.hecksagon`/`.world` carry words no
  # `.bluebook` file could). Uses `InMemoryDomain::ROOT` directly, not
  # aliased to a local `ROOT` — a bare one collides with
  # project_rust_pipeline_spec.rb's own (see load_hygiene_spec.rb).
  CORPUS_GLOBS = [
    File.join(InMemoryDomain::ROOT, "examples", "*", "**", "*.bluebook"),
    File.join(InMemoryDomain::ROOT, "examples", "*", "**", "*.hecksagon"),
    File.join(InMemoryDomain::ROOT, "examples", "*", "**", "*.world"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/grammar", "*.bluebook"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook", "*.bluebook"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook", "*.hecksagon"),
    # The Hecks domain (ADR 0080): the first real users of `namespace` and `attaches`.
    File.join(InMemoryDomain::ROOT, "lib/hecks/hecks", "*.bluebook"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/hecks", "*.hecksagon"),
    # Stress domains: real domains the QA rotation sweeps, not invented
    # fixtures. spec/fixtures stays out — those are invented for one spec.
    File.join(InMemoryDomain::ROOT, "qa/stress_domains", "*", "**", "*.bluebook"),
    File.join(InMemoryDomain::ROOT, "qa/stress_domains", "*", "**", "*.hecksagon"),
    File.join(InMemoryDomain::ROOT, "qa/stress_domains", "*", "**", "*.world"),
    # `.port` — real, non-synthetic port declarations the framework binds
    # against (`Hecks.port "..." do verb "..." ; signal :... end` calls).
    File.join(InMemoryDomain::ROOT, "lib/hecks/ports", "*.port"),
    # `.adapter` — same reasoning, one artifact over: real driven adapters.
    File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven", "*.adapter")
  ].freeze

  # `**` must stay recursive to reach nested sub-language files, but that
  # also reaches examples/*/data/eras/** — gitignored, machine-local era
  # snapshots, not committed corpus source — so those are excluded here.
  def corpus_files
    @corpus_files ||= CORPUS_GLOBS.flat_map { |glob| Dir.glob(glob) }
                                  .reject { |path| path.include?("/data/eras/") }
                                  .sort.freeze
  end

  # Whole-token match on a real (non-comment) line, not anchored to the
  # line's start — calls like `list_of(LedgerEntry)` nest inside another
  # line. `exclude_extension:` narrows by file type, since a naive scan
  # can't otherwise tell one context's spelling of a word from another's
  # (e.g. `.port`'s own `Port` context vs `.bluebook`'s `DomainPort`).
  def corpus_uses?(word, exclude_extension: nil)
    pattern = /\b#{Regexp.escape(word)}\b/
    corpus_files.any? do |path|
      next false if exclude_extension && File.extname(path) == exclude_extension

      File.foreach(path).any? do |line|
        next false if line.lstrip.start_with?("#")

        match = line.match(pattern)
        match && !inside_quotes?(line, match.begin(0))
      end
    end
  end

  # A real call is always a bareword (`rename :old, to: :new`); only its
  # arguments are quoted. An odd `"` count before the match means it sits
  # inside a still-open string, so it's data, not a call.
  def inside_quotes?(line, index)
    line[0...index].count('"').odd?
  end

  # Shared reasoning for 6 of the remaining Translation-family entries below.
  TRANSLATION_RULE_GAP =
    "no real translation edge in this corpus exercises this rule kind — " \
    "examples/pizzas/bluebook/translations/2-77625c.bluebook and " \
    "examples/directory/bluebook/translations/2-632545.bluebook (the two real " \
    "translations this repository has) only exercise `aggregate ... was:`, " \
    "`move ... to:`, `compute ... to:, sql:`, and `rekey sql:`. `corpus_uses?`'s " \
    "naive whole-token scan reports a false positive for this word regardless " \
    "(see the comment on the first entry in this group), so this exemption " \
    "also stands in for that scanner gap.".freeze

  # Same shape as plurality_coverage_spec.rb's ALLOWED_SINGLETON: each
  # entry is a verified finding, not an assumption. The check below
  # flags one as stale once the corpus grows to cover it.
  EXEMPT = {
    "attaches (Hecksagon)"              =>
                                           "its first real user is the `attaches` line in lib/hecks/hecks/hecks.hecksagon, " \
                                           "which ADR 0080's 3.0 build adds when Hecks attaches the language chapters " \
                                           "(commit 6 of 11); that commit drops this exemption. " \
                                           "spec/hecksagon_attaches_spec.rb covers the word meanwhile.",
    "cursor (Query)"                  =>
                                           "refused unconditionally at build (QueryBuilder#seal_cursor) — no interpreter " \
                                           "implements cursor pagination, so any real declaration would refuse the bluebook " \
                                           "that carried it. \"A real chapter uses cursor\" and \"the corpus builds\" are " \
                                           "mutually exclusive claims. S15 (ADR 0026) removes it from the core grammar; " \
                                           "landing a corpus use here first would be work S15 immediately discards.",
    "cursor (ReadModel)"                =>
                                           "same as cursor (Query) — refused unconditionally by ReadModelBuilder#seal_cursor.",
    "inspect_query (Query)"             =>
                                           "a real declaration would be vacuous: no adapter in this codebase implements the " \
                                           "inspect_query hook (Ports::Query.validate!'s own only-a-capability-gate " \
                                           "reading), " \
                                           "so a corpus member declaring it would exercise nothing this doctest does not " \
                                           "already. The gap is upstream of the DSL word, in the adapter layer.",
    "inspect_query (ReadModel)"         =>
                                           "even more vacuous than the Query form — the read model runtime never " \
                                           "reaches the " \
                                           "code this word gates at all, so a real declaration is strictly inert.",
    "tells (DomainPort)"                =>
                                           "identical to operation, which pizzas' real PaymentGateway.Receive " \
                                           "already proves " \
                                           "for real — the two words fill the same PortOperation construct, so a second " \
                                           "corpus use under a different spelling would mean inventing a second inbound " \
                                           "integration this codebase does not otherwise need, for a word that changes " \
                                           "nothing about what the runtime does once declared.",
    "verb (DomainPort)"                 =>
                                           "every resource port a real domain here needs (persisted_by/projected_by/" \
                                           "opened_by) is a framework-level default, never a project's own `port \"X\" do " \
                                           "verb \"...\" end` — nothing in examples/ or lib/hecks/framework/ needs a " \
                                           "swappable resource port of its own. writing-an-adapter.md's own worked example " \
                                           "is the closest this repo has, and it is a guide, not a corpus member.",
    "asks (DomainPort)"                 =>
                                           "the OUTBOUND port direction (the domain asking the outside a question and " \
                                           "reading back an answer/refusal) has no real external integration modeled " \
                                           "anywhere in this corpus — every real port here (pizzas' PaymentGateway) is " \
                                           "inbound (`operation`). ADR 0025's own count claimed this passed; re-checked " \
                                           "against the current corpus while writing this spec and found it does not — a " \
                                           "real, previously-unnoticed drift, not a fact carried over from the ADR.",
    "answers (PortOperation)"           =>
                                           "same finding as asks (DomainPort) — an `asks` operation's own happy ending, " \
                                           "and there is no real `asks` operation to carry one.",
    "refuses (PortOperation)"           =>
                                           "same finding as asks (DomainPort) — an `asks` operation's own refused ending.",
    "attaches_to (Bluebook)"            =>
                                           "genuinely, load-bearingly used for real — lib/hecks/language/bluebook/" \
                                           "attaches/paging.bluebook declares `attaches_to \"Query\", \"ReadModel\"`, read " \
                                           "at every boot by SyntaxBoot's own generic discovery (ADR 0026, S15) — but that " \
                                           "file sits inside lib/hecks/language/bluebook, excluded from CORPUS_GLOBS " \
                                           "on purpose (the language describing itself is not what this corpus counts, the " \
                                           "same reason every core grammar word's own name is not scanned as a use of " \
                                           "itself). A sub-language chapter is caught by the same exclusion its own words " \
                                           "are, even though — unlike formerly_known_as below — it is not a synthetic gap; " \
                                           "it is a real declaration the scanner is not pointed at.",
    "formerly_known_as (Bluebook)"      =>
                                           "no bluebook in THIS repository's own corpus renames itself — real, external " \
                                           "use is what this word is for: a downstream client project's bluebook (a separate " \
                                           "repository, outside this one) declares `formerly_known_as` with its previous " \
                                           "domain name for real, bridging real production journal/era/approval rows the " \
                                           "day it deployed under the new name. Written up in " \
                                           "docs/implemented/reference/bluebook.md's own section, describing " \
                                           "the external consumer, per principle 4's own wording.",
    "bounded (Hecksagon)"               =>
                                           "a consumer-owned mark; framework and vendored packages get it automatically " \
                                           "from uses_framework / uses_embryonaut_bluebook and never write the word. No " \
                                           "corpus member currently owns a chapter that is itself a BC with a translates " \
                                           "ACL — every real BC in this repo is a framework member (Governance, Identity). " \
                                           "The running example lives on docs/implemented/reference/hecksagon.md.",
    # has_many/has_one build for real and mint the same Reference-typed
    # attribute reference_to does, but no real aggregate here picks them
    # over plain reference_to/belongs_to yet.
    "has_many (Aggregate)"              =>
                                           "no real aggregate in this corpus declares a required-or-listed relationship " \
                                           "with has_many/has_one over plain reference_to/belongs_to yet — see the note " \
                                           "above this entry.",
    "has_one (Aggregate)"               => "same as has_many (Aggregate) — see the note above.",
    "has_many (Entity)"                 =>
                                           "same underlying gap as has_many (Aggregate) — EntityBuilder#has_many mints the " \
                                           "identical Reference-typed attribute reference_to does, genuinely live, but no " \
                                           "real entity in this corpus (Account#Ledger entry, ATMCard#Withdrawal, ...) " \
                                           "declares a listed relationship this way over a plain attribute/reference_to " \
                                           "yet. docs/implemented/reference/entity.md's own fixture runs it for " \
                                           "real, which is the " \
                                           "doctest bar, not this one.",
    "has_one (Entity)"                  => "same as has_many (Entity), one word over — EntityBuilder#has_one.",
    "then_set (Command)"                =>
                                           "refused unconditionally at build outside MetaValidator.shadow_parsing? " \
                                           "(CommandBuilder#then_set_impl) — sets is the word now; a live declaration " \
                                           "exists only to be refused, never to succeed.",
    # `corpus_uses?`'s naive whole-token scan false-positives on these:
    # retired/rename/convert/drop/retype/backfill/unresolved all also
    # appear as plain string data in translation.bluebook's own unrelated
    # Rule.Kind closed set (plus "retired" as a status string in
    # banking.bluebook/expression.bluebook). Verified by hand: the two
    # real translations here (examples/pizzas, examples/directory) only
    # exercise aggregate/move/compute/rekey, which is why those need no
    # exemption while the remaining rule kinds still lack a real edge.
    "retired (Translation)"             => TRANSLATION_RULE_GAP,
    "rename (TranslationAggregate)"     => TRANSLATION_RULE_GAP,
    "convert (TranslationAggregate)"    => TRANSLATION_RULE_GAP,
    "drop (TranslationAggregate)"       => TRANSLATION_RULE_GAP,
    "retype (TranslationAggregate)"     => TRANSLATION_RULE_GAP,
    "backfill (TranslationAggregate)"   => TRANSLATION_RULE_GAP,
    "unresolved (TranslationAggregate)" =>
                                           "same finding as the rest of this group, plus a second, independent reason: " \
                                           "`unresolved` is a deliberate failure marker (TranslationAggregateBuilder#" \
                                           "unresolved always raises Malformed) — a real declaration exists only to be " \
                                           "refused, the same structural-impossibility shape `cursor (Query)` above " \
                                           "already is, never to succeed and land in a corpus record.",
    "translates (Hecksagon)"            =>
                                           "used for real in lib/hecks/tenancy/bluebook/tenancy.hecksagon, a tooling-" \
                                           "internal domain (booted centrally, never uses_framework-attached) in the " \
                                           "same category CORPUS_GLOBS above already excludes for lib/hecks/deploy — " \
                                           "neither is an example domain, a grammar chapter, or a framework member. " \
                                           "Also directly, independently tested in spec/hecksagon_translates_spec.rb, " \
                                           "which proves it builds a real Policy and fires end to end, not just parses."
  }.freeze

  it "gives every declared word a real corpus use or a written, named exemption" do
    missing = Hecks::Doc::Reference.live_words(File.join(InMemoryDomain::ROOT, "docs/implemented/reference"))
                                   .reject { |word, _context, _prose| corpus_uses?(word) }
                                   .map { |word, context, _prose| Hecks::Doc::Reference.name_of(word, context) }

    unnamed = missing - EXEMPT.keys

    expect(unnamed).to be_empty, <<~WHY
      These live words carry no real corpus declaration — only doctest
      fixtures invented on their own reference page — and nothing says
      why:

        #{unnamed.join("\n        ")}

      Either add a real declaration somewhere in examples/,
      lib/hecks/grammar/, or lib/hecks/framework/bluebook/,
      or add a reasoned entry to EXEMPT naming why one would be
      synthetic, vacuous, or impossible.
    WHY
  end

  # A stale exemption is how a gate quietly stops gating — mirrors
  # plurality_coverage_spec.rb's own sibling check.
  it "carries no exemption the corpus has outgrown" do
    # DomainPort/PortOperation words can't appear for real in a `.port`
    # file (a different context — see corpus_uses?) — excluded so real
    # `.port` coverage of Port's own words doesn't collide with these.
    PORT_FILE_ONLY_CONTEXTS = %w[DomainPort PortOperation].freeze

    stale = EXEMPT.keys.select do |name|
      word, context = name.match(/\A(.+) \((.+)\)\z/)&.captures
      word && corpus_uses?(word, exclude_extension: PORT_FILE_ONLY_CONTEXTS.include?(context) ? ".port" : nil)
    end

    expect(stale).to be_empty,
                     "the corpus now declares #{stale.join(', ')} for real — " \
                     "delete the EXEMPT entry, the claim is covered now"
  end

  # Pins that corpus_uses? can return true at all — otherwise the checks
  # above are vacuously green.
  it "measures a corpus use it is known to have" do
    expect(corpus_uses?("invariant")).to be(true),
                                         "banking's own Account.invariant went missing, or the walk stopped seeing it"
  end
end
