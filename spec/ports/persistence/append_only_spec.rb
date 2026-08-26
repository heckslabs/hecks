require "hecks"

# `AppendOnly#record_event` used to be an endless method with a trailing
# `if` modifier — `def record_event(event) = @adapter.record_event(event)
# if @adapter.respond_to?(:record_event)`. That modifier binds to the
# WHOLE `def`, not just its body, so it evaluated `@adapter.respond_to?`
# against `@adapter` at class-body time (still nil, before any instance
# exists) and silently skipped defining the method at all — the exact
# gotcha `events` right above it in append_only.rb already carries a
# comment warning about. Every adapter's OWN `record_event` (Memory,
# Postgres, PostgresEra, Sqlite, D1) was, and is, written correctly;
# `emission.rb`'s `repository.record_event(event) if
# repository.respond_to?(:record_event)` simply never reached them,
# because `repository` (the AppendOnly wrapper) never answered true to
# that `respond_to?` check. Every declared `emits` was still computed and
# reported (`registry.event_log`, an in-process array gone at exit) —
# just never durably recorded. Caught live: a tail of a domain's own
# persisted events found nothing to tail.
#
# `sqlite_spec.rb`/`postgres_spec.rb`/`postgres_era_spec.rb` all call
# `adapter.record_event` directly, bypassing this wrapper entirely —
# which is exactly why none of them noticed. This spec goes through the
# wrapper, the way a real dispatch (`Runtime::CommandRules::Emission#emit`)
# always does.
RSpec.describe Hecks::Ports::Persistence::AppendOnly do
  include InMemoryDomain

  let(:runtime) { boot_in_memory }

  it "record_event is a real, callable method — not silently undefined" do
    expect(described_class.method_defined?(:record_event)).to be(true)
  end

  it "forwards record_event to an adapter that implements it" do
    runtime.dispatch("Pizzas::Order.CreatePizza",
                     name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })

    repository = runtime.registry.repository("Pizzas", runtime.registry.bluebooks["Pizzas"].aggregates.first)

    expect(repository.events.map(&:name)).to include("PizzaCreated")
  end

  it "record_event no-ops rather than raising for an adapter that does not implement it" do
    adapter = double(append: nil, project: nil, entries: [])
    repository = described_class.new(adapter)

    expect { repository.record_event(:whatever) }.not_to raise_error
  end
end
