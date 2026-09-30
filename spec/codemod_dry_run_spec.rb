require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks"
require "hecks/codemod"
require "hecks/query_ir"
require "hecks/tools/hoist_local_givens"

# A codemod's dry run judges each edit without writing the file it edits: an interrupted run, or a
# reader in another process, never sees an intermediate bluebook.
RSpec.describe Hecks::Tools::HoistLocalGivens, ".run_files" do
  let(:pizzas) { File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook") }
  let(:repeated) { 'given("a pizza needs at least one topping") { toppings.size.positive? }' }
  let(:source) do
    File.read(pizzas).sub('given("at most 10 toppings")            { toppings.size < 10 }', repeated)
  end

  around do |example|
    Dir.mktmpdir("codemod-dry-run-") do |dir|
      @file = File.join(dir, "pizzas.bluebook")
      File.write(@file, source)
      File.utime(Time.at(1_000_000), Time.at(1_000_000), @file)
      example.run
    end
  end

  it "finds the repeated rule in the scratch domain" do
    result = described_class.run_files([@file], dry_run: true)

    expect(result[:status]).to eq(:applied)
    expect(result[:candidates].map(&:description)).to eq(["a pizza needs at least one topping"])
  end

  it "never writes the file during a dry run" do
    written = []
    allow(File).to receive(:write).and_wrap_original do |original, path, *rest, **options|
      written << path
      original.call(path, *rest, **options)
    end

    described_class.run_files([@file], dry_run: true)

    expect(written).not_to include(@file)
    expect(File.read(@file)).to eq(source)
    expect(File.mtime(@file)).to eq(Time.at(1_000_000))
  end

  it "shows the file unchanged from inside the run, at every load" do
    seen = []
    allow(Hecks::Codemod).to receive(:load_bluebook).and_wrap_original do |original, *args|
      seen << File.read(@file)
      original.call(*args)
    end

    described_class.run_files([@file], dry_run: true)

    expect(seen).not_to be_empty
    expect(seen.uniq).to eq([source])
  end

  it "still rewrites the file when it is not a dry run" do
    result = described_class.run_files([@file], dry_run: false)

    expect(result[:status]).to eq(:applied)
    expect(File.read(@file)).to include('given("a pizza needs at least one topping") { toppings.size.positive? }')
    expect(File.read(@file)).not_to eq(source)
  end

  it "leaves no staged text behind after a dry run" do
    described_class.run_files([@file], dry_run: true)

    expect(Hecks::Codemod::Shadow).not_to be_active
    expect(Hecks::Codemod.load_bluebook([@file])).to be_a(Hecks::Runtime::Registry)
  end
end
