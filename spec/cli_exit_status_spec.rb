require "spec_helper"
require "stringio"

# The statuses a launcher exits with (`ExitStatus`): one set, pinned where each is produced, so a
# script can branch on them. The runner runs against pizzas in-process;
# neither prints or exits.
RSpec.describe Hecks::Adapters::Driving::ExitStatus do
  let(:runtime) { boot_in_memory }
  let(:runner) { Hecks::Adapters::Driving::CliRunner }

  def answer(*argv) = runner.call(runtime: runtime, argv: argv, program: "hecks")
  def status(*argv) = answer(*argv).last
  def create(name) = status("order.create_pizza!", "name=#{name}", "pizza.price_cents.cents=900", "pizza.size.value=large")
  def purchase(id) = status("order.purchase!", "id=#{id}", "customer_name=Chris", "amount.cents=900")
  def usage_of(*argv) = status(*argv)

  describe "answered" do
    it("is 0") { expect(described_class::ANSWERED).to eq(0) }
    it("the usage") { expect(status).to eq(0) }
    it("--help") { expect(status("--help")).to eq(0) }
    it("a command's help") { expect(status("order.create_pizza!", "--help")).to eq(0) }
    it("a command that ran") { expect(create("A")).to eq(0) }
    it("a query") { expect(status("order.available")).to eq(0) }
    it("the launcher's --help") { expect(usage_of("--help")).to eq(0) }

    it "a stream that ended" do
      allow(runtime).to receive(:query).and_return([{ events: [], cursor: nil }])
      expect(runner.run_stream(runtime, query_spec, [], StringIO.new, 1)).to eq(0)
    end
  end

  describe "refused" do
    it("is 1") { expect(described_class::REFUSED).to eq(1) }

    it "the domain's own refusal" do
      create("B")
      expect(purchase("B")).to eq(1)
    end

    it("a record that is not there") { expect(purchase("nope")).to eq(1) }
    it("a settled run that failed") { expect(runner.finish("{}", ["why"])[1]).to eq(1) }
    it("a stream the domain refused") { expect(runner.refuse(StringIO.new, "no")).to eq(1) }
  end

  describe "usage" do
    it("is 2") { expect(described_class::USAGE).to eq(2) }
    it("no command named") { expect(status("query")).to eq(2) }
    it("a command the bluebook does not declare") { expect(status("order.nope")).to eq(2) }
    it("a query the bluebook does not declare") { expect(status("query", "order.nope")).to eq(2) }
    it("a word the command does not take") { expect(status("order.create_pizza!", "nope=1")).to eq(2) }
    it("a value its type cannot hold") { expect(status("order.create_pizza!", "pizza.price_cents.cents=lots")).to eq(2) }
    it("a flag the command lacks") { expect(status("order.create_pizza!", "name=X", "--no-such-flag")).to eq(2) }
    it("the launcher given no word answers its listing") { expect(usage_of).to eq(0) }
    it("the launcher's unknown word") { expect(usage_of("frobnicate")).to eq(2) }
    it("the launcher's retired word") { expect(usage_of("docs", "domain=/nowhere/at/all")).to eq(2) }
  end

  describe "the table" do
    def pizzas = runtime.registry.bluebook("Pizzas")
    def usage(opted) = Hecks::Projector.call(:cli, bluebook: pizzas, options: { opted: opted })[:usage]

    it("ends the help of a launcher that opted in") { expect(usage(true)).to include(described_class::HELP_LINE) }
    it("is left out of one that did not, whose tail folds every status to 1") { expect(usage(false)).not_to include("exit ") }

    it "is the one the compatibility page states", :aggregate_failures do
      page = File.read(File.expand_path("../docs/compatibility.md", __dir__))
      [0, 1, 2].each { |code| expect(page).to include("| `#{code}` |") }
    end
  end

  # The projected spec of a pizzas question, for a stream that asks it once.
  def query_spec = runner.resolve(runtime, ["order.available"], "hecks")[:spec]
end
