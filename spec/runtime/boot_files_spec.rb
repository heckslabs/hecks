RSpec.describe "Hecks.boot_files" do
  let(:root) { File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook") }
  let(:memory_hecksagon) { File.join(InMemoryDomain::ROOT, "examples/pizzas/pizzas_behaviors.hecksagon") }

  def boot_files_runtime
    Hecks.boot_files([File.join(root, "pizzas.bluebook"), memory_hecksagon], install_driving: false)
  end

  def create_pizza(runtime, name, cents:, size:)
    runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                          name:  { value: name },
                          pizza: { price_cents: { cents: cents }, size: { value: size } })
  end

  it "dispatches identically to a directory boot of the same domain", :aggregate_failures do
    runtime = boot_files_runtime
    result = create_pizza(runtime, "Margherita", cents: 1200, size: "large")

    expect(result.events.map(&:name)).to eq(["PizzaCreated"])
    expect(runtime.query("Pizzas::Order.Available").map { |row| row[:id] }).to eq(["Margherita"])
  end

  it "loads the exact files named — no directory glob, no sibling file picked up by accident" do
    runtime = boot_files_runtime

    # "Governance" arrives via `attaches` inside the hecksagon, not
    # from a directory glob — the point this proves is that nothing else
    # under examples/pizzas/bluebook/ (the real pizzas.hecksagon, say)
    # snuck in.
    expect(runtime.registry.bluebooks.keys).to eq(["Pizzas", "Governance"])
  end

  it "boots against the real file paths, not a copy — no side effects between calls" do
    first  = boot_files_runtime
    second = boot_files_runtime

    create_pizza(first, "First", cents: 900, size: "small")

    expect(second.query("Pizzas::Order.Available")).to eq([])
  end

  it "raises the ordinary LoadError for a file that doesn't exist" do
    expect do
      Hecks.boot_files([File.join(root, "nope.bluebook")], install_driving: false)
    end.to raise_error(LoadError)
  end

  describe "an .adapter among the files" do
    let(:directory) { Dir.mktmpdir("boot-files-adapters") }

    after { FileUtils.remove_entry(directory) }

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
      path
    end

    def adapter_names(*extra)
      files = [File.join(root, "pizzas.bluebook"), memory_hecksagon, *extra]
      Hecks.boot_files(files, shared: directory, install_driving: false).registry.adapters.keys
    end

    it "loads the adapter named" do
      stand_in = write(File.join(directory, "stand_in.adapter"), "Hecks.adapter(\"StandIn\") { port \"Stand\" }\n")

      expect(adapter_names(stand_in)).to include("StandIn")
    end

    it "leaves the shared root's own adapters unloaded" do
      write(File.join(directory, "adapters", "real.adapter"), "Hecks.adapter(\"Real\") { port \"Stand\" }\n")
      stand_in = write(File.join(directory, "stand_in.adapter"), "Hecks.adapter(\"StandIn\") { port \"Stand\" }\n")

      expect(adapter_names(stand_in)).not_to include("Real")
    end

    it "still loads the shared root's adapters when none is named" do
      write(File.join(directory, "adapters", "real.adapter"), "Hecks.adapter(\"Real\") { port \"Stand\" }\n")

      expect(adapter_names).to include("Real")
    end
  end
end
