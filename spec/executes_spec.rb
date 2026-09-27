require "spec_helper"

# The meta-domain holds a bluebook and reads it back through its own queries.
# Covers the chapter and its aggregates, not yet equality with the builder's `to_h`.
RSpec.describe "the language holds a bluebook, and gives it back" do
  def pizzas
    @pizzas ||= begin
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))
      end
      registry.bluebook("Pizzas")
    end
  end

  # Dispatches a real bluebook into the meta-domain and keeps the runtime.
  # `pizzas` must load first: loading judges into the shared grammar_registry, and
  # `fresh_runtime` then resets it so the manual `judge!` declares into a clean store.
  def held
    @held ||= begin
      pizzas
      runtime = Hecks::Bluebook::MetaValidator.fresh_runtime
      judge   = Hecks::Bluebook::MetaValidator::Judge.allocate
      judge.instance_variable_set(:@bluebook, pizzas)
      judge.instance_variable_set(:@refusals, [])
      judge.instance_variable_set(:@runtime, runtime)
      judge.instance_variable_set(
        :@plan,
        Hecks::Bluebook::MetaValidator::Plan.for(Hecks::Bluebook::MetaValidator.grammar_registry)
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

  it "gives back the bluebook called Pizzas" do
    rows = runtime.query("Bluebook::Bluebook.Called", name: { value: "Pizzas" })

    expect(rows.size).to eq(1)
    expect(text(rows.first[:name])).to eq(pizzas.name)
    expect(text(rows.first[:vision])).to eq(pizzas.vision)
    expect(text(rows.first[:classification])).to eq(pizzas.classification)
  end

  it "gives back every aggregate declared in it" do
    rows = runtime.query("Bluebook::Aggregate.DeclaredIn", bluebook: { value: "Pizzas" })

    expect(rows.map { |row| text(row[:name]) }).to eq(pizzas.aggregates.map(&:name))
  end

  it "hands back the whole bluebook in one read" do
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
    # "Pizzas:Order" is the record's derived id (bluebook:name.value), not the
    # "Pizzas::Order" constant path.
    rows = runtime.query("Bluebook::Command.DeclaredIn", aggregate: { value: "Pizzas:Order" })

    expect(rows.map { |row| text(row[:name]) })
      .to eq(pizzas.aggregate("Order").commands.map(&:hecks_name))
  end

  it "keeps the order that changes behaviour" do
    # Behaviour-bearing order must survive a round trip: mutations apply in sequence,
    # a lifecycle takes the first matching transition, a compensation credits first.
    whole    = runtime.query("Bluebook.whole_bluebook", bluebook: "Pizzas").first
    purchase = whole[:commands].find { |c| text(c[:name]) == "Purchase" }
    source   = pizzas.aggregate("Order").command("Purchase")

    expect(purchase[:mutations].map { |m| text(m[:target]) })
      .to eq(source.mutations.map { |m| m.target.to_s })
    expect(purchase[:emits].map { |e| text(e[:name]) }).to eq(source.emits)
  end

  it "normalises the order that does not" do
    # Command listing order is presentation only (lookup is by name), and stores do
    # not iterate stably, so head lists are compared sorted.
    whole    = runtime.query("Bluebook.whole_bluebook", bluebook: "Pizzas").first
    declared = pizzas.aggregate("Order").commands.map(&:hecks_name)

    expect(whole[:commands].map { |c| text(c[:name]) }).to eq(declared.sort)
  end

  it "names a gathered collection the way English does" do
    expect(Hecks::Naming.plural("query")).to eq("queries")
    expect(Hecks::Naming.plural("entity")).to eq("entities")
    expect(Hecks::Naming.plural("policy")).to eq("policies")
    expect(Hecks::Naming.plural("dispatch")).to eq("dispatches")
    expect(Hecks::Naming.plural("value_object")).to eq("value_objects")
    # a vowel before the y is not a plural rule — day, not daies
    expect(Hecks::Naming.plural("day")).to eq("days")
  end

  # Banking is the only corpus member with a cross-aggregate reference.
  def banking
    @banking ||= begin
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      end
      registry.bluebook("Banking")
    end
  end

  # `banking` loads first, for the same reason as in `held`.
  def held_account_attributes
    @held_account_attributes ||= begin
      banking
      runtime = Hecks::Bluebook::MetaValidator.fresh_runtime
      judge   = Hecks::Bluebook::MetaValidator::Judge.allocate
      judge.instance_variable_set(:@bluebook, banking)
      judge.instance_variable_set(:@refusals, [])
      judge.instance_variable_set(:@runtime, runtime)
      judge.instance_variable_set(
        :@plan,
        Hecks::Bluebook::MetaValidator::Plan.for(Hecks::Bluebook::MetaValidator.grammar_registry)
      )
      judge.send(:judge!)
      raise "banking refused: #{judge.instance_variable_get(:@refusals).inspect}" unless
        judge.instance_variable_get(:@refusals).empty?

      account = runtime.query("Bluebook::Aggregate.DeclaredIn", bluebook: { value: "Banking" })
                       .find { |row| text(row[:name]) == "Account" }
      account[:attributes].to_h { |a| [text(a[:name]), text(a[:type])] }
    end
  end

  it "holds an attribute as the ID of whatever its type names" do
    # Ids join with ":", not the "::" constant path; "::" survives only in the wire
    # format ("Reference<Customer>"), produced on the way out (see the next test).
    held = held_account_attributes

    expect(held["number"]).to eq("Banking:Account:AccountNumber") # a value object
    expect(held["customer"]).to eq("Banking:Customer") # another head
    expect(held["ledger"]).to eq("Banking:Account:LedgerEntry") # a piece it holds
  end

  it "re-encodes a reference into the type the IR spells" do
    # The meta-domain holds the head; Readings derives the `Reference<Customer>` spelling.
    reader = Object.new.extend(Hecks::Bluebook::MetaValidator::Readings)

    expect(reader.reference_type("Banking::Customer")).to eq("Reference<Customer>")
    expect(reader.reference_type(held_account_attributes["customer"]))
      .to eq(banking.aggregate("Account").attribute(:customer).type.to_s)
  end

  it "reads through the aggregate's own query, not a repository" do
    # Reading a repository directly would bypass the rules and authorisation every
    # writer goes through.
    expect(Hecks::Bluebook::MetaValidator.grammar_registry
             .bluebook("Bluebook").aggregates
             .flat_map { |a| a.queries.map { |q| "#{a.name}.#{q.name}" } })
      .to include("Bluebook.Called", "Aggregate.DeclaredIn")
  end
end
