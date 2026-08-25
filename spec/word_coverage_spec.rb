require "spec_helper"
require "hecks/doc/reference"

# S13, ADR 0025 — "A word earns its place by being used. A word stays if
# it has a real corpus use AND a running doctest. An external consumer
# outside this repo is a valid exemption from the corpus bar, written
# down and naming the consumer, never assumed." (principle 4)
#
# `bin/doc_coverage`/`spec/reference_golden_spec.rb` already close the
# DOCTEST half — every live word must carry prose AND a fenced, running
# example. Neither checks the OTHER half: a doctest can run against a
# chapter INVENTED for the page alone (`docs/implemented/reference/*.md` do this
# routinely — a synthetic `QueryReference`/`DomainPortReference`/
# `WorldReference` bluebook, declared in the page's own fenced block,
# solely so the harness has something to execute), which satisfies
# `unexemplified` while never once landing in a real bluebook a real
# domain ships. ADR 0025's own "Coverage standard" section names this
# exact failure mode: "The doctest bar alone is what let the inert words
# through — `consistency` had a running example demonstrating it being
# *declared*, which is precisely the thing not in question."
#
# So this asks a DIFFERENT question: does any REAL corpus member — an
# example domain, a grammar chapter, a framework member — actually
# WRITE this word, in its own `.bluebook`/`.hecksagon`/`.world` file? A
# word that only a doc page's own invented fixture exercises answers no,
# and must be named here with a reason, the same shape
# `plurality_coverage_spec.rb`'s ALLOWED_SINGLETON already is for a
# different claim.
RSpec.describe "every live DSL word, used somewhere real" do
  # THE SAME FILE FAMILY spec/corpus_spec.rb's CORPUS_MEMBERS walks —
  # example domains, grammar chapters, framework members — widened to
  # every extension a real domain ships across (`.hecksagon`/`.world`
  # carry hecksagon/world words that no `.bluebook` file ever could).
  # `InMemoryDomain::ROOT` directly, not aliased to a local `ROOT` — a
  # bare `ROOT` collided with project_rust_pipeline_spec.rb's own (see
  # load_hygiene_spec.rb's own top-level-constant check).
  CORPUS_GLOBS = [
    File.join(InMemoryDomain::ROOT, "examples", "*", "**", "*.bluebook"),
    File.join(InMemoryDomain::ROOT, "examples", "*", "**", "*.hecksagon"),
    File.join(InMemoryDomain::ROOT, "examples", "*", "**", "*.world"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/grammar", "*.bluebook"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook", "*.bluebook"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook", "*.hecksagon"),
    # `.port` — REAL, non-synthetic production declarations (13 real
    # ports the framework itself binds against), unlike the S15 Paging
    # precedent's own seed-row false-positive risk (a naive whole-token
    # scan matching DATA, not a real use of the word) — these genuinely
    # ARE `Hecks.port "..." do verb "..." ; signal :... end` calls.
    # Whole-project table-unification survey, item #13's remaining
    # builders.
    File.join(InMemoryDomain::ROOT, "lib/hecks/ports", "*.port"),
    # `.adapter` — same reasoning, one artifact over: 6+ real, non-
    # synthetic driven adapters (Memory, Postgres, Sqlite, D1, ...).
    File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven", "*.adapter")
  ].freeze

  # `examples/*/**/*.bluebook`'s own `**` has to be recursive — a
  # nested sub-language file (`examples/pizzas/bluebook/translations/
  # 2-77625c.bluebook`) is a real corpus source one directory deeper
  # than `examples/pizzas/bluebook/*.bluebook` itself — but that same
  # recursion also reaches `examples/*/data/eras/**`, the RUNTIME era
  # store a file adapter writes locally (.gitignore's own `**/data/
  # eras/` entry, anchored to `data/` for the identical reason: era
  # snapshots are real generated content, not committed corpus source,
  # and an environment that has actually minted an era — running
  # bin/evolve/project_deploy against a real domain, say — would see
  # this scanner "find" a word only ever frozen into a historical
  # snapshot, on a machine where nobody else could ever reproduce it).
  # Excluded here the same way corpus_spec.rb's own walk never has the
  # problem in the first place — its own glob never descends into
  # `data/` at all.
  def corpus_files
    @corpus_files ||= CORPUS_GLOBS.flat_map { |glob| Dir.glob(glob) }
                                  .reject { |path| path.include?("/data/eras/") }
                                  .sort.freeze
  end

  # A REAL DECLARATION, not a mention — the word as a whole token
  # anywhere on a REAL (non-comment) line. Not anchored to the line's
  # start: `list_of(LedgerEntry)` is a type-position call nested inside
  # an `attribute` line, `Hecks.bluebook "X" do`/`Pizzas::Order.port
  # "PaymentGateway"` carry a receiver before the word this grammar's
  # own line-oriented calls elsewhere don't. A full-line `# comment` is
  # excluded by checking only lines whose first non-whitespace
  # character is not `#` — this codebase's own comment style never
  # trails code on the same line, confirmed by reading every file this
  # walks. False positives are possible in principle (the word inside a
  # string literal) but none of the words checked below have one in
  # this corpus — confirmed by reading each finding this spec reports
  # before writing its exemption.
  # `exclude_extension:` — a naive whole-token scan cannot tell one
  # CONTEXT'S spelling of a word from another's (`verb` inside a `.port`
  # file's own `Port` context vs `verb` inside a `.bluebook`'s own
  # nested `domain_port` block's `DomainPort` context — same word,
  # different grammar, same S15 Paging precedent's own "naive scanner,
  # not context-aware" finding) — but a FILE EXTENSION genuinely can:
  # a `.port` file structurally cannot ever contain a `DomainPort`-
  # context word, so excluding it from a `DomainPort` exemption's own
  # staleness check is a real, structural narrowing, not a guess.
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

  # THE OTHER FALSE-POSITIVE RISK the header above already names — "the
  # word inside a string literal" — turned into a real check, not just a
  # read-every-finding promise, once Translation/TranslationAggregate's
  # own coverage (item #13's remaining builders) hit it for real:
  # `lib/hecks/grammar/translation.bluebook`'s own UNRELATED `Rule
  # .Kind` closed set (`one_of: ["rename", "move", "convert", ...]`) and
  # ordinary English prose (`given("a retired rule ...")`) both contain
  # this language's own rule-word SPELLINGS as plain string DATA, not as
  # a live keyword call. A real call in this codebase is always a
  # bareword — `rename :old, to: :new`, `retired "OldAggregate"` — never
  # itself quoted; only the call's own ARGUMENTS are. A double-quote
  # parity count up to the match's own position tells the two apart: an
  # odd count of `"` before it means the match sits inside an still-open
  # quote, so it is DATA, not a call.
  def inside_quotes?(line, index)
    line[0...index].count('"').odd?
  end

  # Shared reasoning for 8 of the 9 Translation-family entries below —
  # see the comment on the first of them for the full finding.
  TRANSLATION_RULE_GAP =
    "no real translation edge in this corpus exercises this rule kind — " \
    "examples/pizzas/bluebook/translations/2-77625c.bluebook (the one real " \
    "translation this repository has) only exercises `aggregate ... was:` and " \
    "`move ... to:`. `corpus_uses?`'s naive whole-token scan reports a false " \
    "positive for this word regardless (see the comment on the first entry in " \
    "this group), so this exemption also stands in for that scanner gap."

  # UNREACHED ON PURPOSE, each naming why — the same shape
  # plurality_coverage_spec.rb's ALLOWED_SINGLETON is. Every entry here
  # is a real, verified finding (checked against the current corpus
  # when written), not an assumption; delete an entry once the corpus
  # grows to cover it and this spec will say so on its own.
  EXEMPT = {
    "cursor (Query)"                       =>
                                              "refused unconditionally at build (QueryBuilder#seal_cursor) — no interpreter " \
                                              "implements cursor pagination, so any real declaration would refuse the bluebook " \
                                              "that carried it. \"A real chapter uses cursor\" and \"the corpus builds\" are " \
                                              "mutually exclusive claims. S15 (ADR 0026) removes it from the core grammar; " \
                                              "landing a corpus use here first would be work S15 immediately discards.",
    "cursor (ReadModel)"                   =>
                                              "same as cursor (Query) — refused unconditionally by ReadModelBuilder#seal_cursor.",
    "inspect_query (Query)"                =>
                                              "a real declaration would be vacuous: no adapter in this codebase implements the " \
                                              "inspect_query hook (Ports::Query.validate!'s own only-a-capability-gate reading), " \
                                              "so a corpus member declaring it would exercise nothing this doctest does not " \
                                              "already. The gap is upstream of the DSL word, in the adapter layer.",
    "inspect_query (ReadModel)"            =>
                                              "even more vacuous than the Query form — the read model runtime never reaches the " \
                                              "code this word gates at all, so a real declaration is strictly inert.",
    "tells (DomainPort)"                   =>
                                              "identical to operation, which pizzas' real PaymentGateway.Receive already proves " \
                                              "for real — the two words fill the same PortOperation construct, so a second " \
                                              "corpus use under a different spelling would mean inventing a second inbound " \
                                              "integration this codebase does not otherwise need, for a word that changes " \
                                              "nothing about what the runtime does once declared.",
    "verb (DomainPort)"                    =>
                                              "every resource port a real domain here needs (persisted_by/projected_by/" \
                                              "opened_by) is a framework-level default, never a project's own `port \"X\" do " \
                                              "verb \"...\" end` — nothing in examples/ or lib/hecks/framework/ needs a " \
                                              "swappable resource port of its own. writing-an-adapter.md's own worked example " \
                                              "is the closest this repo has, and it is a guide, not a corpus member.",
    "asks (DomainPort)"                    =>
                                              "the OUTBOUND port direction (the domain asking the outside a question and " \
                                              "reading back an answer/refusal) has no real external integration modeled " \
                                              "anywhere in this corpus — every real port here (pizzas' PaymentGateway) is " \
                                              "inbound (`operation`). ADR 0025's own count claimed this passed; re-checked " \
                                              "against the current corpus while writing this spec and found it does not — a " \
                                              "real, previously-unnoticed drift, not a fact carried over from the ADR.",
    "answers (PortOperation)"              =>
                                              "same finding as asks (DomainPort) — an `asks` operation's own happy ending, " \
                                              "and there is no real `asks` operation to carry one.",
    "refuses (PortOperation)"              =>
                                              "same finding as asks (DomainPort) — an `asks` operation's own refused ending.",
    "attaches_to (Bluebook)"               =>
                                              "genuinely, load-bearingly used for real — lib/hecks/language/bluebook/" \
                                              "attaches/paging.bluebook declares `attaches_to \"Query\", \"ReadModel\"`, read " \
                                              "at every boot by SyntaxBoot's own generic discovery (ADR 0026, S15) — but that " \
                                              "file sits inside lib/hecks/language/bluebook, excluded from CORPUS_GLOBS " \
                                              "on purpose (the language describing itself is not what this corpus counts, the " \
                                              "same reason every core grammar word's own name is not scanned as a use of " \
                                              "itself). A sub-language chapter is caught by the same exclusion its own words " \
                                              "are, even though — unlike formerly_known_as below — it is not a synthetic gap; " \
                                              "it is a real declaration the scanner is not pointed at.",
    "formerly_known_as (Bluebook)"         =>
                                              "no bluebook in THIS repository's own corpus renames itself — real, external " \
                                              "use is what this word is for: embryonautfoundersapp.bluebook (the sibling " \
                                              "embryonaut_console repo) declares `formerly_known_as \"Embryonaut\"` for real, " \
                                              "bridging real production journal/era/approval rows the day it deployed under " \
                                              "the new name. Written up in docs/implemented/reference/bluebook.md's own section, naming " \
                                              "the consumer, per principle 4's own wording.",
    # NO LONGER REFUSED. `AggregateBuilder#has_many`/`#has_one` genuinely
    # build now (S17/ADR 0026's relationship-cardinality slice un-
    # deprecated all three words — `belongs_to` is real corpus use today,
    # `examples/banking/bluebook/safe_deposit_boxes.bluebook`'s own
    # `belongs_to Customer`, which is why belongs_to (Aggregate) carries
    # no entry here at all). `has_many`/`has_one` mint the identical
    # `Reference`-typed attribute `reference_to` does (`relationship_
    # attribute`, shared by all four words) — genuinely live, just not
    # yet the spelling any REAL aggregate in this corpus happens to
    # choose over plain `reference_to`/`belongs_to` for a required or
    # list-shaped relationship. `docs/implemented/reference/aggregate.md`'s own
    # fixture runs both for real (the doctest bar), but a doc page's own
    # invented fixture is explicitly not what this file counts (see this
    # file's own header) — finishing that adoption in a real domain is
    # separate, larger corpus work, not a defect in either word.
    "has_many (Aggregate)"                 =>
                                              "no real aggregate in this corpus declares a required-or-listed relationship " \
                                              "with has_many/has_one over plain reference_to/belongs_to yet — see the note " \
                                              "above this entry.",
    "has_one (Aggregate)"                  => "same as has_many (Aggregate) — see the note above.",
    "has_many (Entity)"                    =>
                                              "same underlying gap as has_many (Aggregate) — EntityBuilder#has_many mints the " \
                                              "identical Reference-typed attribute reference_to does, genuinely live, but no " \
                                              "real entity in this corpus (Account#Ledger entry, ATMCard#Withdrawal, ...) " \
                                              "declares a listed relationship this way over a plain attribute/reference_to " \
                                              "yet. docs/implemented/reference/entity.md's own fixture runs it for real, which is the " \
                                              "doctest bar, not this one.",
    "has_one (Entity)"                     => "same as has_many (Entity), one word over — EntityBuilder#has_one.",
    # `then_set (Command)` — the OTHER kind of structural impossibility this
    # file's own header distinguishes from a mere corpus gap: refused
    # unconditionally at build outside MetaValidator.shadow_parsing?
    # (CommandBuilder#then_set_impl); sets is the word now, and no live
    # declaration of then_set can ever succeed to be a corpus example of.
    "then_set (Command)"                   =>
                                              "refused unconditionally at build outside MetaValidator.shadow_parsing? " \
                                              "(CommandBuilder#then_set_impl) — sets is the word now; a live declaration " \
                                              "exists only to be refused, never to succeed.",
    "uses_embryonaut_bluebook (Hecksagon)" =>
                                              "no hecksagon in THIS repository's own corpus vendors an embryonaut bluebook — " \
                                              "real, external use is what this word is for: lifeadelics/domain (a hecks-" \
                                              "based service, not part of this repository) declares `uses_embryonaut_bluebook " \
                                              "\"payments\"` for real, attaching embryonaut_bluebooks/payments' Payment " \
                                              "aggregate — a full settle/refund/dispute lifecycle shared across every project " \
                                              "that needs one rather than reimplemented per project. Written up in " \
                                              "docs/implemented/reference/hecksagon.md's own section, naming the consumer, per principle " \
                                              "4's own wording — same shape formerly_known_as (Bluebook) above already is.",
    # Translation/TranslationAggregate — item #13's remaining builders.
    # `corpus_uses?` is a NAIVE whole-token scan (its own header already
    # names this risk) with no context awareness at all, and every one of
    # these 9 words happens to collide with an UNRELATED real corpus use
    # of the same spelling: `retired`/`rename`/`convert`/`drop`/`retype`/
    # `compute`/`rekey`/`backfill`/`unresolved` all appear as plain STRING
    # VALUES inside lib/hecks/grammar/translation.bluebook's own
    # unrelated `Rule.Kind` closed set (a pre-existing, different self-
    # hosted "Translation" domain — governs proposing/executing/admitting
    # individual rules for bin/evolve's scaffold tooling, never loaded
    # into the same registry as this one) — plus `retired` also collides
    # with the word "retired" appearing as a plain lifecycle STATUS
    # STRING in banking.bluebook/expression.bluebook. Read and confirmed
    # by hand, one file at a time, not assumed: `examples/pizzas/bluebook/
    # translations/2-77625c.bluebook` is the one REAL translation this
    # corpus has (a genuine `Hecks.data_translation "Pizzas", ... do
    # aggregate "Order", was: "Pizza" do move ... end end` — which is why
    # `data_translation (File)`, `aggregate (Translation)`, and `move
    # (TranslationAggregate)` need no exemption here, all three genuinely
    # covered), and it exercises exactly two of the nine rule words
    # (`aggregate ... was:`, `move ... to:`). The other nine rule kinds
    # this language admits have no real edge exercising them anywhere in
    # this repository yet — a real gap in the CORPUS, not in the words.
    "retired (Translation)"                => TRANSLATION_RULE_GAP,
    "rename (TranslationAggregate)"        => TRANSLATION_RULE_GAP,
    "convert (TranslationAggregate)"       => TRANSLATION_RULE_GAP,
    "drop (TranslationAggregate)"          => TRANSLATION_RULE_GAP,
    "retype (TranslationAggregate)"        => TRANSLATION_RULE_GAP,
    "compute (TranslationAggregate)"       => TRANSLATION_RULE_GAP,
    "rekey (TranslationAggregate)"         => TRANSLATION_RULE_GAP,
    "backfill (TranslationAggregate)"      => TRANSLATION_RULE_GAP,
    "unresolved (TranslationAggregate)"    =>
                                              "same finding as the rest of this group, plus a second, independent reason: " \
                                              "`unresolved` is a deliberate failure marker (TranslationAggregateBuilder#" \
                                              "unresolved always raises Malformed) — a real declaration exists only to be " \
                                              "refused, the same structural-impossibility shape `cursor (Query)` above " \
                                              "already is, never to succeed and land in a corpus record."
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

  # THE EXEMPTIONS ARE HELD TO THE CORPUS TOO — an entry the corpus has
  # since grown to cover is a stale excuse, and a stale excuse is how a
  # gate quietly stops gating (plurality_coverage_spec.rb's own sibling
  # check, same reasoning).
  it "carries no exemption the corpus has outgrown" do
    stale = EXEMPT.keys.select do |name|
      word, context = name.match(/\A(.+) \((.+)\)\z/)&.captures
      # `DomainPort`'s own words can never appear for real in a `.port`
      # file (a structurally different context/file type — see
      # corpus_uses?'s own header) — excluded here so adding real `.port`
      # coverage for `Port`'s own words (verb/signal) doesn't collide
      # with this SIBLING context's own, still-genuinely-unused claim.
      word && corpus_uses?(word, exclude_extension: context == "DomainPort" ? ".port" : nil)
    end

    expect(stale).to be_empty,
                     "the corpus now declares #{stale.join(', ')} for real — " \
                     "delete the EXEMPT entry, the claim is covered now"
  end

  # THE MEASUREMENT ITSELF HAS TO BE ABLE TO FAIL — a real, known corpus
  # use (banking's own `invariant`) has to read as covered, or the check
  # above is vacuously green because corpus_uses? never returns true.
  it "measures a corpus use it is known to have" do
    expect(corpus_uses?("invariant")).to be(true),
                                         "banking's own Account.invariant went missing, or the walk stopped seeing it"
  end
end
