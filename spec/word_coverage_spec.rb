require "spec_helper"
require "hecksagain/doc/reference"

# S13, ADR 0025 — "A word earns its place by being used. A word stays if
# it has a real corpus use AND a running doctest. An external consumer
# outside this repo is a valid exemption from the corpus bar, written
# down and naming the consumer, never assumed." (principle 4)
#
# `bin/doc_coverage`/`spec/reference_golden_spec.rb` already close the
# DOCTEST half — every live word must carry prose AND a fenced, running
# example. Neither checks the OTHER half: a doctest can run against a
# chapter INVENTED for the page alone (`docs/reference/*.md` do this
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
  ROOT = InMemoryDomain::ROOT

  # THE SAME FILE FAMILY spec/corpus_spec.rb's CORPUS_MEMBERS walks —
  # example domains, grammar chapters, framework members — widened to
  # every extension a real domain ships across (`.hecksagon`/`.world`
  # carry hecksagon/world words that no `.bluebook` file ever could).
  CORPUS_GLOBS = [
    File.join(ROOT, "examples", "*", "**", "*.bluebook"),
    File.join(ROOT, "examples", "*", "**", "*.hecksagon"),
    File.join(ROOT, "examples", "*", "**", "*.world"),
    File.join(ROOT, "lib/hecksagain/grammar", "*.bluebook"),
    File.join(ROOT, "lib/hecksagain/framework/bluebook", "*.bluebook"),
    File.join(ROOT, "lib/hecksagain/framework/bluebook", "*.hecksagon")
  ].freeze

  def corpus_files
    @corpus_files ||= CORPUS_GLOBS.flat_map { |glob| Dir.glob(glob) }.sort.freeze
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
  def corpus_uses?(word)
    pattern = /\b#{Regexp.escape(word)}\b/
    corpus_files.any? do |path|
      File.foreach(path).any? { |line| !line.lstrip.start_with?("#") && line.match?(pattern) }
    end
  end

  # UNREACHED ON PURPOSE, each naming why — the same shape
  # plurality_coverage_spec.rb's ALLOWED_SINGLETON is. Every entry here
  # is a real, verified finding (checked against the current corpus
  # when written), not an assumption; delete an entry once the corpus
  # grows to cover it and this spec will say so on its own.
  EXEMPT = {
    "cursor (Query)" =>
      "refused unconditionally at build (QueryBuilder#seal_cursor) — no interpreter " \
      "implements cursor pagination, so any real declaration would refuse the bluebook " \
      "that carried it. \"A real chapter uses cursor\" and \"the corpus builds\" are " \
      "mutually exclusive claims. S15 (ADR 0026) removes it from the core grammar; " \
      "landing a corpus use here first would be work S15 immediately discards.",
    "cursor (ReadModel)" =>
      "same as cursor (Query) — refused unconditionally by ReadModelBuilder#seal_cursor.",
    "inspect_query (Query)" =>
      "a real declaration would be vacuous: no adapter in this codebase implements the " \
      "inspect_query hook (Ports::Query.validate!'s own only-a-capability-gate reading), " \
      "so a corpus member declaring it would exercise nothing this doctest does not " \
      "already. The gap is upstream of the DSL word, in the adapter layer.",
    "inspect_query (ReadModel)" =>
      "even more vacuous than the Query form — the read model runtime never reaches the " \
      "code this word gates at all, so a real declaration is strictly inert.",
    "tells (DomainPort)" =>
      "identical to operation, which pizzas' real PaymentGateway.Receive already proves " \
      "for real — the two words fill the same PortOperation construct, so a second " \
      "corpus use under a different spelling would mean inventing a second inbound " \
      "integration this codebase does not otherwise need, for a word that changes " \
      "nothing about what the runtime does once declared.",
    "verb (DomainPort)" =>
      "every resource port a real domain here needs (persisted_by/projected_by/" \
      "opened_by) is a framework-level default, never a project's own `port \"X\" do " \
      "verb \"...\" end` — nothing in examples/ or lib/hecksagain/framework/ needs a " \
      "swappable resource port of its own. writing-an-adapter.md's own worked example " \
      "is the closest this repo has, and it is a guide, not a corpus member.",
    "asks (DomainPort)" =>
      "the OUTBOUND port direction (the domain asking the outside a question and " \
      "reading back an answer/refusal) has no real external integration modeled " \
      "anywhere in this corpus — every real port here (pizzas' PaymentGateway) is " \
      "inbound (`operation`). ADR 0025's own count claimed this passed; re-checked " \
      "against the current corpus while writing this spec and found it does not — a " \
      "real, previously-unnoticed drift, not a fact carried over from the ADR.",
    "answers (PortOperation)" =>
      "same finding as asks (DomainPort) — an `asks` operation's own happy ending, " \
      "and there is no real `asks` operation to carry one.",
    "refuses (PortOperation)" =>
      "same finding as asks (DomainPort) — an `asks` operation's own refused ending.",
    "formerly_known_as (Bluebook)" =>
      "no bluebook in THIS repository's own corpus renames itself — real, external " \
      "use is what this word is for: embryonautfoundersapp.bluebook (the sibling " \
      "embryonaut_console repo) declares `formerly_known_as \"Embryonaut\"` for real, " \
      "bridging real production journal/era/approval rows the day it deployed under " \
      "the new name. Written up in docs/reference/bluebook.md's own section, naming " \
      "the consumer, per principle 4's own wording.",
    "has_many (Aggregate)" =>
      "refused unconditionally at build outside MetaValidator.shadow_parsing? " \
      "(AggregateBuilder#has_many) — the same structural impossibility cursor has. " \
      "reference_to mints the identical attribute now; a live declaration exists only " \
      "to be refused, never to succeed.",
    "has_one (Aggregate)" => "same as has_many (Aggregate) — AggregateBuilder#has_one.",
    "belongs_to (Aggregate)" => "same as has_many (Aggregate) — AggregateBuilder#belongs_to."
  }.freeze

  it "gives every declared word a real corpus use or a written, named exemption" do
    missing = Hecksagain::Doc::Reference.live_words(File.join(ROOT, "docs/reference"))
                                        .reject { |word, _context, _prose| corpus_uses?(word) }
                                        .map { |word, context, _prose| Hecksagain::Doc::Reference.name_of(word, context) }

    unnamed = missing - EXEMPT.keys

    expect(unnamed).to be_empty, <<~WHY
      These live words carry no real corpus declaration — only doctest
      fixtures invented on their own reference page — and nothing says
      why:

        #{unnamed.join("\n        ")}

      Either add a real declaration somewhere in examples/,
      lib/hecksagain/grammar/, or lib/hecksagain/framework/bluebook/,
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
      word && corpus_uses?(word)
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
