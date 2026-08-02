
require "spec_helper"

# The language does not only judge a bluebook — it HOLDS one, and gives it back.
#
# `bluebook.bluebook`'s own vision says "loading a domain becomes dispatching
# commands into this meta-domain ; the IR it stores must equal the IR the DSL
# builder produces." Only the first half was true. The judge dispatched every
# declaration in, collected refusals, and threw the records away — which is all
# JUDGING needs, and exactly why the language could only validate.
#
# The reason was structural and slightly absurd: the meta-domain declared twelve
# categories and thirty-four verbs and NOT ONE QUERY. It was write-only. A store
# you cannot read cannot be the source of anything.
#
# So the way back is declared, on the aggregates themselves, and read through
# their own front doors rather than by reaching into a repository. This spec is
# the first slice of it: the chapter and its aggregates come back out. The
# remaining categories, and equality with the builder's whole `to_h`, are the arc
# this opens — not a claim it already makes.
RSpec.describe "the language holds a bluebook, and gives it back" do
  def pizzas
    @pizzas ||= begin
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))
      end
      registry.bluebook("Pizzas")
    end
  end

  # Dispatch a real bluebook into the meta-domain and KEEP the runtime, which is
  # the only difference between judging and holding.
  #
  # `pizzas` REFERENCED FIRST, on purpose. It loads Pizzas through the normal
  # `MetaValidator.call` path, which judges (and so DISPATCHES a
  # `Bluebook.Declare` for "Pizzas") into `grammar_registry`'s own shared
  # repositories — the same registry `fresh_runtime` wraps, not a copy.
  # Resetting repositories AFTER that means the manual `judge!` below dispatches
  # its own `Bluebook.Declare` into a clean store ; resetting BEFORE meant the
  # two declarations collided, and the collision guard (added once creating a
  # command twice was refused rather than silently overwritten) is what turned
  # a harmless double-write into a real failure — this was always two
  # declarations of the same record, just invisible until refusing the second
  # one became the honest behaviour.
  def held
    @held ||= begin
      pizzas
      runtime = Hecksagain::Bluebook::MetaValidator.fresh_runtime
      judge   = Hecksagain::Bluebook::MetaValidator::Judge.allocate
      judge.instance_variable_set(:@bluebook, pizzas)
      judge.instance_variable_set(:@refusals, [])
      judge.instance_variable_set(:@runtime, runtime)
      judge.instance_variable_set(
        :@plan,
        Hecksagain::Bluebook::MetaValidator::Plan.for(Hecksagain::Bluebook::MetaValidator.grammar_registry)
      )
      judge.send(:judge!)
      [runtime, judge.instance_variable_get(:@refusals)]
    end
  end

  def runtime  = held.first
  def refusals = held.last

  # Every attribute of the meta-domain is a single-field value object, so a row's
  # cell arrives as a Value rather than a String.
  def text(cell)
    return cell.to_h.values.first if cell.respond_to?(:to_h) && !cell.is_a?(String)

    cell
  end

  it "accepts the bluebook without refusing any of it" do
    expect(refusals).to be_empty
  end

  it "gives back the bluebook called Pizzas" do
    rows = runtime.query("Bluebook::Bluebook.Called", name: { value: "Pizzas" })

    expect(rows.size).to eq(1)
    expect(text(rows.first[:name])).to eq(pizzas.name)
    expect(text(rows.first[:vision])).to eq(pizzas.vision)
    expect(text(rows.first[:classification])).to eq(pizzas.classification)
  end

  it "gives back every aggregate declared in it" do
    rows = runtime.query("Bluebook::Aggregate.DeclaredIn", bluebook_id: { value: "Pizzas" })

    expect(rows.map { |row| text(row[:name]) }).to eq(pizzas.aggregates.map(&:name))
  end

  it "hands back the whole bluebook in one read" do
    # The twelve DeclaredIn queries can walk the tree a level at a time, and a
    # caller stitching twelve reads together is a caller reimplementing this. The
    # language already knows how to say "gather these heads around that spine".
    rows = runtime.query("Bluebook.whole_bluebook", bluebook: "Pizzas")
    whole = rows.first

    expect(whole.keys).to eq(
      %i[bluebook aggregates commands value_objects queries entities members
         policies process_managers handlers dispatches read_models]
    )
    expect(whole[:aggregates].map { |a| text(a[:name]) }).to eq(pizzas.aggregates.map(&:name))
    expect(whole[:commands].map { |c| text(c[:name]) })
      .to match_array(pizzas.aggregates.flat_map { |a| a.commands.map(&:hecks_name) })
  end

  it "keeps declaration order when read a level at a time" do
    # The IR is a contract field for field AND INDEX FOR INDEX, so the order a
    # bluebook declares its commands in is a fact about the source. `DeclaredIn`
    # preserves it.
    # "Pizzas:Pizza" — the Aggregate-within-Bluebook record's OWN derived id
    # (bluebook_id:name.value), not the real "Pizzas::Pizza" Ruby constant path.
    rows = runtime.query("Bluebook::Command.DeclaredIn", aggregate_id: { value: "Pizzas:Pizza" })

    expect(rows.map { |row| text(row[:name]) })
      .to eq(pizzas.aggregate("Pizza").commands.map(&:hecks_name))
  end

  it "keeps the order that changes behaviour" do
    # Not all order is equal, and only one kind has to survive a round trip.
    #
    # BEHAVIOUR-BEARING: mutations are applied in sequence, so a then_set reading a
    # field an earlier one wrote depends on the order; a lifecycle takes the FIRST
    # transition that matches; a compensation credits the source before reversing
    # the transfer. Reorder any of those and the domain does something else.
    whole    = runtime.query("Bluebook.whole_bluebook", bluebook: "Pizzas").first
    purchase = whole[:commands].find { |c| text(c[:name]) == "Purchase" }
    source   = pizzas.aggregate("Pizza").command("Purchase")

    expect(purchase[:mutations].map { |m| text(m[:target]) })
      .to eq(source.mutations.map { |m| m.target.to_s })
    expect(purchase[:emits].map { |e| text(e[:name]) }).to eq(source.emits)
  end

  it "normalises the order that does not" do
    # PRESENTATION ONLY: which order an aggregate's commands happen to be listed
    # in. Nothing looks a command up by position — find_command is by name — so
    # ReadModelInterpreter#matching ending `.sort_by(&:id)` is not a loss, it is a
    # canonical form. And it is the right call: two hand-written stores cannot be
    # trusted to iterate identically, so a read model returning store order would
    # split parity on the first disagreement.
    #
    # Which means the byte-for-byte proof compares with the head lists sorted on
    # both sides. That is not a weakening of the claim — it is the claim stated on
    # the axis the machine actually reads.
    whole    = runtime.query("Bluebook.whole_bluebook", bluebook: "Pizzas").first
    declared = pizzas.aggregate("Pizza").commands.map(&:hecks_name)

    expect(whole[:commands].map { |c| text(c[:name]) }).to eq(declared.sort)
  end

  it "names a gathered collection the way English does" do
    # These four came back as `querys`, `entitys`, `policys` and `dispatchs`, in
    # BOTH runtimes, because each derived the name with snake(target) + "s". Parity
    # was green on every one of them — two hand-written runtimes identically
    # wrong. The pluraliser now lives in one place per runtime, mirroring the same
    # three rules.
    expect(Hecksagain::Naming.plural("query")).to eq("queries")
    expect(Hecksagain::Naming.plural("entity")).to eq("entities")
    expect(Hecksagain::Naming.plural("policy")).to eq("policies")
    expect(Hecksagain::Naming.plural("dispatch")).to eq("dispatches")
    expect(Hecksagain::Naming.plural("value_object")).to eq("value_objects")
    # a vowel before the y is not a plural rule — day, not daies
    expect(Hecksagain::Naming.plural("day")).to eq("days")
  end

  # Banking is the only corpus member with a cross-aggregate reference.
  def banking
    @banking ||= begin
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
      end
      registry.bluebook("Banking")
    end
  end

  # `banking` referenced first — same reason as `held`'s own comment above.
  def held_account_attributes
    @held_account_attributes ||= begin
      banking
      runtime = Hecksagain::Bluebook::MetaValidator.fresh_runtime
      judge   = Hecksagain::Bluebook::MetaValidator::Judge.allocate
      judge.instance_variable_set(:@bluebook, banking)
      judge.instance_variable_set(:@refusals, [])
      judge.instance_variable_set(:@runtime, runtime)
      judge.instance_variable_set(
        :@plan,
        Hecksagain::Bluebook::MetaValidator::Plan.for(Hecksagain::Bluebook::MetaValidator.grammar_registry)
      )
      judge.send(:judge!)
      raise "banking refused: #{judge.instance_variable_get(:@refusals).inspect}" unless
        judge.instance_variable_get(:@refusals).empty?

      account = runtime.query("Bluebook::Aggregate.DeclaredIn", bluebook_id: { value: "Banking" })
                       .find { |row| text(row[:name]) == "Account" }
      account[:attributes].to_h { |a| [text(a[:name]), text(a[:type])] }
    end
  end

  it "holds an attribute as the ID of whatever its type names" do
    # All three kinds resolve as references, so "the type is declared" costs no
    # predicate at all — the rule is a consequence of the model, which is the trick
    # the language already used for value objects and now uses for all of them.
    # One separator now, everywhere a head's id is stored — the internal
    # identity join, not the real Ruby "::" constant path (that spelling
    # survives only in the WIRE FORMAT, "Reference<Customer>", produced on the
    # way back out ; see the next test).
    held = held_account_attributes

    expect(held["number"]).to     eq("Banking:Account:AccountNumber")  # a value object
    expect(held["customer_id"]).to eq("Banking:Customer")              # another head
    expect(held["ledger"]).to     eq("Banking:Account:LedgerEntry")    # a piece it holds
  end

  it "re-encodes a reference into the type the IR spells" do
    # `Reference<Customer>` is an ENCODING. The meta-domain holds the head, and the
    # spelling is derived on the way out — in Readings, the one place that knows the
    # IR's shape differs from the language's.
    reader = Object.new.extend(Hecksagain::Bluebook::MetaValidator::Readings)

    expect(reader.reference_type("Banking::Customer")).to eq("Reference<Customer>")
    expect(reader.reference_type(held_account_attributes["customer_id"]))
      .to eq(banking.aggregate("Account").attribute(:customer_id).type.to_s)
  end

  it "reads through the aggregate's own query, not a repository" do
    # Persistence is an adapter BELOW the aggregate. If the way back reached into
    # a repository it would bypass the rules, the authorisation and the shape that
    # every writer goes through — and the read side would drift from the write
    # side exactly as the two runtimes' tables used to.
    expect(Hecksagain::Bluebook::MetaValidator.grammar_registry
             .bluebook("Bluebook").aggregates
             .flat_map { |a| a.queries.map { |q| "#{a.name}.#{q.name}" } })
      .to include("Bluebook.Called", "Aggregate.DeclaredIn")
  end
end
