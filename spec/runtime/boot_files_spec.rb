RSpec.describe "Hecks.boot_files" do
  let(:root) { File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook") }
  let(:memory_hecksagon) { File.join(InMemoryDomain::ROOT, "examples/pizzas/pizzas_behaviors.hecksagon") }

  def boot_files_runtime
    Hecks.boot_files([File.join(root, "pizzas.bluebook"), memory_hecksagon], install_facade: false)
  end

  it "dispatches identically to a directory boot of the same domain" do
    runtime = boot_files_runtime
    result = runtime.dispatch("Pizzas::Order.CreatePizza",
                              name:  { value: "Margherita" },
                              pizza: { price_cents: { cents: 1200 }, size: { value: "large" } })

    expect(result.events.map(&:name)).to eq(["PizzaCreated"])
    expect(runtime.query("Pizzas::Order.Available").map { |row| row[:id] }).to eq(["Margherita"])
  end

  it "loads the exact files named — no directory glob, no sibling file picked up by accident" do
    runtime = boot_files_runtime

    # "Governance" arrives via `uses_framework` inside the hecksagon, not
    # from a directory glob — the point this proves is that nothing else
    # under examples/pizzas/bluebook/ (the REAL pizzas.hecksagon, say)
    # snuck in.
    expect(runtime.registry.bluebooks.keys).to eq(["Pizzas", "Governance"])
  end

  it "boots against the real file paths, not a copy — no side effects between calls" do
    first  = boot_files_runtime
    second = boot_files_runtime

    first.dispatch("Pizzas::Order.CreatePizza", name:  { value: "First" },
                                                pizza: { price_cents: { cents: 900 }, size: { value: "small" } })

    expect(second.query("Pizzas::Order.Available")).to eq([])
  end

  it "raises the ordinary LoadError for a file that doesn't exist" do
    expect do
      Hecks.boot_files([File.join(root, "nope.bluebook")], install_facade: false)
    end.to raise_error(LoadError)
  end
end
