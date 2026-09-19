require "spec_helper"

# A regression guard for the O(N^2) boot cost `Adapters::Memory#bootstrap_
# fast_path?`'s own header traces start to finish. The language's own
# self-hosted grammar boots by dispatching every declaration in `lib/hecks/
# language/bluebook/` into a fresh, private `Memory` store
# (`MetaValidator.grammar_registry`), and every dispatch that touches an
# entity nested under an aggregate (a `ValueObject`'s own `Member`, and each
# `Member`'s own `Pair` — S17, ADR 0026) re-saves the whole parent
# aggregate, because an entity has no storage of its own. A 128-row
# `member` table added to `vocabulary.bluebook`, without a fix, alone
# tripled one aggregate's own save time (6.7s -> 18.2s) by re-encoding
# an aggregate whose own state kept growing, on every one of ~1,160 extra
# saves.
#
# **A save count, not a duration** — the task this file backs is explicit that
# a wall-clock assertion flakes on CI; a save count is deterministic. It
# does not, on its own, distinguish O(N) dispatches from the O(N^2) cost
# the real bug was (this fix changed the cost per save, not how many saves
# happen) — but a budget on the count is still real protection against the
# other half of the same failure mode: a future change that dispatches a
# save more than once per declared row (the mechanism a naive fix — or a
# second accidental table — could reintroduce), and it is the fast, non-
# flaky signal available without instrumenting wall-clock.
#
# Today's real numbers (measured against this same commit, warm cache):
# total saves during a full `grammar_registry` boot ~6,346 ; the busiest
# single aggregate (`ValueObject`, S17's own Member/Pair table) ~5,271.
# Both budgets below give real headroom for organic corpus growth (a new
# vocabulary table, another attached chapter) while still catching a
# regression at that 128-row member table's own scale.
RSpec.describe "grammar boot save budget" do
  # The same reset/restore shape `fixpoint_spec.rb`'s own "registry and the
  # installed door agree from bind" example and `syntax_boot_memo_spec.rb`'s
  # own "boots at most once per distinct chapter set" example already use —
  # `@grammar_registry` is process-global and memoized
  # (`MetaValidator.grammar_registry`'s own `||=`), so this example's own
  # forced rebuild is invisible to whatever else shares this process,
  # including `ir_golden_spec.rb`'s byte-for-byte comparison against a
  # frozen fixture built from the pristine first boot.
  it "does not dispatch more saves than a generous budget while booting the language's own grammar" do
    original_registry = Hecks::Bluebook::MetaValidator.instance_variable_get(:@grammar_registry)
    original_ready_for = Hecks::Bluebook::MetaValidator.instance_variable_get(:@grammar_ready_for)
    # **The verdict cache, also reset** — `MetaValidator.call`'s own `verdicts[key]
    # ||= hold(bluebook)` (keyed on the IR itself, meta_validator.rb's own
    # header) answers a second `grammar_registry` build in the same process
    # from cache without dispatching a single new command, since the
    # language's own grammar content never changes mid-suite. Nil'd here the
    # same way `@grammar_registry` is, or this example measures zero saves
    # (and a `.values.max` on an empty `busiest` hash) the moment any earlier
    # spec in this process has already booted the grammar once — which, in
    # the real suite, is every run but the very first.
    original_verdicts = Hecks::Bluebook::MetaValidator.instance_variable_get(:@verdicts)

    total = 0
    busiest = Hash.new(0)
    # `TracePoint`, not `allow_any_instance_of` (RSpec/AnyInstance, this
    # repo's own rubocop gate) — scoped with `target:` to exactly one
    # method, so it costs nothing for any call this example doesn't care
    # about and leaves no monkeypatch behind for the rest of the process.
    tracer = TracePoint.new(:call) do |tp|
      total += 1
      aggregate = tp.self.aggregate
      busiest[aggregate.respond_to?(:name) ? aggregate.name.to_s : aggregate.to_s] += 1
    end

    begin
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@verdicts, nil)
      tracer.enable(target: Hecks::Ports::Persistence::AppendOnly.instance_method(:save)) do
        Hecks::Bluebook::MetaValidator.grammar_registry
      end
    ensure
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, original_registry)
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@grammar_ready_for, original_ready_for)
      Hecks::Bluebook::MetaValidator.instance_variable_set(:@verdicts, original_verdicts)
    end

    expect(busiest).not_to be_empty
    expect(total).to be < 9_000
    expect(busiest.values.max).to be < 7_500
  end
end
