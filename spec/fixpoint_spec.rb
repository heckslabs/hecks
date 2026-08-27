require "spec_helper"
require "tmpdir"

# The language passes its own rules — and RUNS from its own records.
#
# `lib/hecks/language/bluebook/` declares what a bluebook is, and
# nine rules are now enforced there and nowhere else. It is itself a bluebook —
# so it must satisfy the rules it declares, or the language demands of every
# domain something its own definition does not do.
#
# The bootstrap loads it raw (judging it while loading it would recurse), but
# the exemption ends there : `grammar_registry` immediately judges the merged
# chapter through itself and keeps the ASSEMBLED graph, so the language every
# other bluebook is judged by is the one the language itself produced. The
# first example below is the independent proof the judge accepts the chapter (every
# other path is a verdicts-cache hit after boot) ; the last two prove the
# fixpoint is load-bearing, not merely possible.
RSpec.describe "the language's own definition" do
  def meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  it "is judged by the rules it declares, and passes" do
    refusals = Hecks::Bluebook::MetaValidator::Judge.new(meta).refusals

    expect(refusals).to be_empty
  end

  it "declares the shapes a bluebook is made of" do
    # if the language stops describing a category, a bluebook using it stops
    # being judged — silently, since the judge skips what it has no shape for
    expect(meta.aggregates.map(&:name)).to include(
      "Bluebook", "Aggregate", "Command", "ValueObject", "Query", "Entity",
      "Policy", "ProcessManager", "ReadModel", "Vocabulary"
    )

    # S17, ADR 0026 — Member is a genuine entity now, nested under
    # ValueObject rather than its own root aggregate, so it is found
    # through `.entities` here, not `.aggregates`.
    value_object = meta.aggregates.find { |aggregate| aggregate.hecks_name == "ValueObject" }
    expect(value_object.entities.map(&:hecks_name)).to include("Member")
  end

  it "is what actually refuses a malformed bluebook, end to end" do
    # A rule declared but never dispatched cannot fire — five sat in that state
    # after the first pass. So this goes through the real load path rather than
    # calling the judge directly : `emits ""` has no `raise` left in any builder,
    # and is refused only because the language says so.
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "silent.bluebook"), <<~BLUEBOOK)
        Hecks.bluebook "Silent" do
          vision "a command that announces nothing in particular"
          supporting

          aggregate "Thing" do
            description "a thing"
            attribute :label, Label

            value_object "Label" do
              attribute :value, String
            end

            command "Make" do
              role "Someone"
              goal "make a thing"
              attribute :label, Label
              emits ""
            end
          end
        end
      BLUEBOOK

      expect { Hecks.boot(dir) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /an event is named/)
    end
  end

  # THE FIXPOINT IS LOAD-BEARING. The registry's language chapters are the
  # graphs the language assembled from its own records — not the raw builder
  # output — and nothing was lost on the way through.
  #
  # The door-coherence example resets the singleton and binds fresh,
  # deliberately : any spec that binds another runtime repoints the global
  # constants at ITS surface, so "registry and door agree" is only a fact
  # about the moment just after a bind — which is exactly the moment this
  # asserts, whatever order the suite ran in.
  #
  # RESTORED AFTER, not just reset before — `@grammar_registry` is process-
  # global and memoized (MetaValidator.grammar_registry's own `||=`), so
  # nil-ing it here forces a genuine rebuild for THIS example's own purposes,
  # but leaving that rebuild in place afterward means every OTHER spec
  # sharing this process for the rest of its life — including
  # ir_golden_spec.rb's byte-for-byte comparison against a frozen fixture —
  # reads a registry built at THIS moment in suite history, not the
  # pristine first-boot one the golden fixtures were captured against.
  # Found live: an intermittent ir_golden_spec.rb failure under
  # parallel_rspec, order-dependent on whether this example's process
  # happened to run before it — never reproduced under a plain sequential
  # `bundle exec rspec` because this test and ir_golden_spec.rb only race
  # when parallel_rspec's file-to-process assignment puts them in the same
  # worker. Saving and restoring the singleton (a bare `ensure`, the same
  # shape every other spec here already uses to leave shared state as it
  # found it) makes this example's own deliberate reset invisible to
  # whatever runs after it, in this process or any other.
  it "runs from its own records — registry and the installed door agree from bind" do
    original_registry = Hecks::Bluebook::MetaValidator.instance_variable_get(:@grammar_registry)
    original_ready_for = Hecks::Bluebook::MetaValidator.instance_variable_get(:@grammar_ready_for)

    Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
    registry = Hecks::Bluebook::MetaValidator.grammar_registry
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))

    expect(Object.const_get(:Bluebook).const_get(:Aggregate).ir)
      .to be(registry.bluebook("Bluebook").aggregate("Aggregate"))
    expect(Object.const_get(:World).const_get(:World).ir)
      .to be(registry.bluebook("World").aggregate("World"))
  ensure
    Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, original_registry)
    Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_ready_for, original_ready_for)
  end

  # `:members` is compared with its own values stringified on BOTH sides,
  # and only there — a deliberate, narrow exception, not a loophole. L7
  # (docs/audits/2026-08-11-bug-triage.md) fixed `ValueObject#to_h` to stop
  # flattening every member value to text, so `raw` now shows a member
  # field's REAL declared type (`Vocabulary::MutationOp`'s own `sign: "1"`
  # is genuinely a String — the language's own grammar says so,
  # `vocabulary.bluebook`). `Assembly::Marks#member` still runs every
  # value through `unmark_scalar` on the assembled side, on purpose:
  # spec/vocabulary_conformance_spec.rb reads real Ruby `true`/`false`
  # (`compares_less_than: true`, not the source text `"true"`) off exactly
  # this path, and says so in its own header comment. So `raw` and
  # `registry` now genuinely, intentionally disagree on a member field's
  # Ruby type — String there, guessed-typed here — and stringifying both
  # sides' member values before comparing is what still lets this spec
  # hold everything else (every attribute, invariant, closed_set flag,
  # command, lifecycle, ...) to the byte-for-byte standard the fixpoint
  # claims, without re-litigating a difference two other specs already
  # pin on purpose.
  def stringify_members(node)
    case node
    when Hash
      node.to_h { |key, value| [key, key == :members ? stringify_member_rows(value) : stringify_members(value)] }
    when Array
      node.map { |item| stringify_members(item) }
    else
      node
    end
  end

  def stringify_member_rows(rows)
    Array(rows).map { |row| row.map { |field, value| [field, value.to_s] } }
  end

  it "lost nothing on the way through — assembled equals a fresh raw load, chapter for chapter" do
    registry = Hecks::Bluebook::MetaValidator.grammar_registry
    raw = Hecks::Bluebook::MetaValidator.load_grammar_into(Hecks::Runtime::Registry.new)

    Hecks::Bluebook::MetaValidator::LANGUAGE_CHAPTERS.each do |name|
      expect(stringify_members(registry.bluebook(name).to_h)).to eq(stringify_members(raw.bluebook(name).to_h))
    end
  end
end
