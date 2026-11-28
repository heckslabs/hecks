require "spec_helper"
require "json"
require "stringio"
require "hecks/runtime/role_shadow/report"
require "hecks/hecks/adapters/codebase/role_shadow_reading"

# The Ruby runtime's role modes: under `shadow` a role-gated command dispatched by a caller who
# stated no role is logged as `would_refuse_role` in the Rust host's wording and still runs, and the
# static report lists every command and reaction such a caller is refused under `enforce`.
RSpec.describe Hecks::Runtime::RoleShadow do
  def self.pizzas_dir = File.expand_path("../examples/pizzas/bluebook", __dir__)

  def pizzas = @pizzas ||= Hecks.boot(self.class.pizzas_dir)

  def pizza_args(name = "Margherita")
    { name: { value: name }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }
  end

  # The lines a block writes under `mode`, as an outside dispatch sees it: a launcher run of this
  # spec is itself a reaction, so the thread's reacting mark is cleared for the block.
  def lines_under(mode, &)
    pizzas
    sink = StringIO.new
    described_class.write_to(sink)
    described_class.install(mode)
    outside_reaction(&)
    sink.string.lines.map { |line| JSON.parse(line) }
  ensure
    described_class.install(described_class::DEFAULT)
    described_class.write_to(nil)
  end

  def outside_reaction
    reacting = Thread.current[:hecks_reacting]
    Thread.current[:hecks_reacting] = nil
    yield
  ensure
    Thread.current[:hecks_reacting] = reacting
  end

  def create_pizza(name = "Margherita") = pizzas.dispatch_flat("Pizzas::Order.CreatePizza", **pizza_args(name))

  # Runs a block that is refused, keeping only that it was.
  def refusal_of
    yield
  rescue Hecks::Runtime::Unauthorized => e
    e
  end

  def unstated_pizza(name = "Margherita") = Hecks::Runtime::Caller.unstated { create_pizza(name) }

  def unstated_count = pizzas.registry.unstated_caller_log[%w[Pizzas CreatePizza unstated]]

  # Puts the process's mode and sink back; `lines_under` does too, this covers a block that raised.
  def reset_shadow
    described_class.install(described_class::DEFAULT)
    described_class.write_to(nil)
  end

  def gated_command = Struct.new(:hecks_name, :role_set).new("CreatePizza", ["Chef"])

  describe ".parse" do
    it "reads shadow and off by name, and anything else, unset included, as enforce" do
      expect(%w[shadow ENFORCE off nonsense].map { |word| described_class.parse(word) } + [described_class.parse(nil)])
        .to eq(%i[shadow enforce off enforce enforce])
    end
  end

  describe "a role-gated command dispatched by a caller who stated no role" do
    after { reset_shadow }

    it "logs the host's line under shadow and still runs the command", :aggregate_failures do
      lines = lines_under(:shadow) { expect(unstated_pizza.events.map(&:name)).to eq(["PizzaCreated"]) }
      expect(lines).to eq([{ "level" => "error", "msg" => "would_refuse_role", "verb" => "Pizzas::Order.CreatePizza",
                             "role" => "Anonymous", "actor_id" => nil, "refusals" => lines.first["refusals"] }])
      expect(lines.first["refusals"].first).to include("kind" => "Unauthorized")
    end

    it "logs a key once however often it is counted", :aggregate_failures do
      lines = lines_under(:shadow) { %w[Margherita Marinara].each { |name| unstated_pizza(name) } }
      expect(lines.size).to eq(1)
      expect(unstated_count).to eq(2)
    end

    it "logs nothing when the mode is off" do
      expect(lines_under(:off) { unstated_pizza }).to be_empty
    end

    it "logs nothing under enforce, which refuses it" do
      expect(lines_under(:enforce) { refusal_of { unstated_pizza } }).to be_empty
    end

    it "logs the host-internal shape with origin internal for a dispatch with no caller bound" do
      lines = lines_under(:shadow) { create_pizza }
      expect(lines.first).to include("origin" => "internal", "verb" => "Pizzas::Order.CreatePizza", "roles" => ["Chef"])
    end

    it "logs nothing for a caller that states the role" do
      expect(lines_under(:shadow) { Hecks.as_caller(role: "Chef") { create_pizza } }).to be_empty
    end
  end

  describe "a reaction" do
    after { reset_shadow }

    it "logs the host-internal shape with origin reaction" do
      lines = lines_under(:shadow) { Hecks::Runtime::Caller.without(reacting: true) { described_class.note(gated_command, "P::O.C") } }
      expect(lines.first).to include("origin" => "reaction", "verb" => "P::O.C", "roles" => ["Chef"])
    end

    it "is marked reacting, with the caller cleared, by the dispatcher's re-entry, a root policy's too" do
      seen = reentry_probe
      answers = Hecks.as_caller(role: "Chef") { outside_reaction { [seen.reenter("V"), seen.reenter_root("V")] } }
      expect(answers).to eq([[true, nil], [true, nil]])
    end
  end

  def reentry_probe
    probe_class = Class.new do
      include Hecks::Runtime::Dispatcher::RootReentry

      def dispatch_flat(_verb, _args) = [Hecks::Runtime::Caller.reacting?, Hecks::Runtime::Caller.current]
    end
    probe_class.new
  end

  describe Hecks::Runtime::RoleShadow::Report do
    def self.fixture_dir = File.expand_path("fixtures/pizza_fixture/bluebook", __dir__)

    def report = @report ||= described_class.of_directory(self.class.pizzas_dir)

    def fixture_report = described_class.of_directory(self.class.fixture_dir)

    it "lists each role-gated command with its roles" do
      expect(report).to include("command    Pizzas::Order.CreatePizza roles: Chef")
    end

    it "lists a policy whose target is role-gated and that declares no acts_as" do
      row = /^reaction   PizzaFixture::OnPizzaPaymentReceived on .+ -> PizzaFixture::Order\.Purchase roles: Customer$/
      expect(fixture_report).to match(row)
    end

    it "leaves out a policy whose acts_as its target declares" do
      expect(report).not_to match(/^reaction /)
    end

    it "says under its heading what clears each kind of row" do
      expect(report.lines[1]).to start_with("a command row needs its caller to state a role")
    end

    it "counts what it lists in its heading" do
      expect(report.lines.first).to include("7 role-gated commands, 0 reactions to one, 0 unresolved targets")
    end

    # Every reaction this repository's launcher and agent harness run states the role it runs as,
    # so a cascade a stated caller begins is not refused under `enforce`.
    %w[lib/hecks/hecks lib/hecks/harness].each do |domain|
      it "lists no reaction or mismatch row for #{domain}" do
        own = described_class.of_directory(File.join(InMemoryDomain::ROOT, domain))
        expect(own).not_to match(/^(reaction|mismatch) /)
      end
    end
  end

  describe Hecks::Adapters::Codebase::RoleShadowReading do
    it "refuses a record that names no directory" do
      expect { described_class.call(domain: { value: "" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /name a domain/)
    end
  end
end
