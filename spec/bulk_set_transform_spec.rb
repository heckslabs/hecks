require "spec_helper"
require "tmpdir"
require "hecks/fuzzing"

# A bulk run compiles to one update when its store provides `set_transform` (ADR 0128). Each
# example boots a fresh copy of the Lamps fixture on SQLite with three lamps: "a" too dim to dim
# again, "b" and "c" bright enough.
RSpec.describe "a bulk run as one statement" do
  around do |example|
    Dir.mktmpdir("set-transform") do |tmp|
      @tmp = tmp
      Hecks::Runtime::AdapterLookup.standing_in(nil) { example.run }
    end
  end

  def boot
    copy = File.join(@tmp, "lamps")
    Hecks::Fuzzing::IsolatedBoot.copy_dereferencing(File.join(InMemoryDomain::ROOT, "spec/fixtures/set_transform"), copy)
    Hecks::Fuzzing::IsolatedBoot.rebind!(copy, :sqlite, database: nil, schema: nil, scratch: {})
    @runtime = Hecks.boot(copy, environment: nil)
    { "a" => 5, "b" => 25, "c" => 45 }.each do |name, brightness|
      @runtime.dispatch_flat("Lamps::Lamp.Install", name: name, brightness: brightness, wattage: 10)
    end
  end

  def plan(command, mode: "best_effort", query: "Everything")
    Hecks::Bulk::Plan.new(verb: "Lamps::Lamp.#{command}", over: "Lamps::Lamp.#{query}", arguments: {}, mode: mode)
  end

  def sweep(command, mode: "best_effort", set_transform: true)
    Hecks::Bulk::Sweep.new(@runtime.registry, plan(command, mode: mode), set_transform: set_transform).outcomes
  end

  def statement(command) = Hecks::Bulk::SetPlanner.new(@runtime.registry, plan(command), :lamp).statement

  def repository = @runtime.registry.repository("Lamps", @runtime.registry.bluebook("Lamps").aggregate("Lamp"))

  def brightness = repository.all.to_h { |lamp| [lamp.id, lamp[:brightness][:value]] }

  def dim_refusal = { row: "a", delivered: false, reason: "Dim refused — the lamp is bright enough to dim" }

  it "compiles a command over a query to one UPDATE that returns the rows it changed" do
    boot
    expect(repository.adapter.compile_set_transform(statement("Dim")).first).to match(/\AUPDATE "lamp" SET .* RETURNING \*\z/)
  end

  it "leaves a command whose ensures reads the settled record to run row by row" do
    boot
    expect(statement("Brighten")).to be_nil
  end

  it "delivers the rows that meet the givens and words the skipped row's refusal as a dispatch does",
     :aggregate_failures do
    boot
    expect(sweep("Dim")).to eq([dim_refusal, { row: "b", delivered: true }, { row: "c", delivered: true }])
    expect(brightness).to eq("a" => 5, "b" => 15, "c" => 35)
  end

  it "journals one entry per row it changed" do
    boot
    expect { sweep("Dim") }.to change { repository.entries.size }.by(2)
  end

  it "emits one event per row it changed, carrying that row's arguments" do
    boot
    sweep("Relabel")
    facts = @runtime.events.select { |event| event.name == "LampRelabelled" }.map { |event| [event.id, event.payload[:lamp]] }
    expect(facts).to eq([%w[a a], %w[b b], %w[c c]])
  end

  it "rolls every row back under all_or_nothing when the statement skipped one, as row by row does",
     :aggregate_failures do
    boot
    expect(sweep("Dim", mode: "all_or_nothing")).to eq(row_by_row_all_or_nothing)
    expect(brightness).to eq("a" => 5, "b" => 25, "c" => 45)
  end

  def row_by_row_all_or_nothing
    stopped = "not sent: row a refused (Dim refused — the lamp is bright enough to dim)"
    [dim_refusal, { row: "b", delivered: false, reason: stopped }, { row: "c", delivered: false, reason: stopped }]
  end

  it "runs row by row when the store refuses the statement" do
    boot
    allow(repository.adapter).to receive(:run_set_transform).and_raise(Hecks::Adapters::SetTransform::Declined, "overflow")
    expect(sweep("Dim")).to eq([dim_refusal, { row: "b", delivered: true }, { row: "c", delivered: true }])
  end
end
