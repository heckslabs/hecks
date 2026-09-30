require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks"
require "hecks/codemod"
require "hecks/query_ir"
require "hecks/tools/hoist_local_givens"

RSpec.describe Hecks::Codemod::Runner, "#run" do
  let(:pizzas) { File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook") }

  # Finds one candidate in a domain named Pizzas and none in the meta-domain; applying it adds a
  # comment, which leaves the exported IR as it was.
  let(:runner) do
    described_class.new(
      find_candidates: ->(registry) { registry.bluebooks.key?("Pizzas") ? [:touch] : [] },
      apply_candidate: ->(text, _candidate) { text.include?("# touched") ? [text, false] : ["#{text}# touched\n", true] },
      label:           :to_s.to_proc
    )
  end

  before do
    @dir = Dir.mktmpdir("codemod-runner-")
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    @file = File.join(@dir, "bluebook", "pizzas.bluebook")
    FileUtils.cp(pizzas, @file)
    @original = File.read(@file)
    stub_const("Hecks::Codemod::EXAMPLE_ROOTS", [@dir])
  end

  after { FileUtils.remove_entry(@dir) }

  it "judges the edit without writing the file in a dry run, and still counts it applied" do
    written = []
    allow(File).to receive(:write).and_wrap_original do |original, path, *rest, **options|
      written << path
      original.call(path, *rest, **options)
    end

    results = runner.run(dry_run: true)

    expect(results[:applied].map { |row| row[:file] }).to eq([@file])
    expect(written).not_to include(@file)
    expect(File.read(@file)).to eq(@original)
  end

  it "writes the edit when it is not a dry run" do
    runner.run(dry_run: false)

    expect(File.read(@file)).to eq("#{@original}# touched\n")
  end
end
