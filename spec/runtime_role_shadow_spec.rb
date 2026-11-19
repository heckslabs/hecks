require "spec_helper"
require "json"
require "stringio"
require "hecks/runtime/role_shadow/report"
require "hecks/hecks/adapters/codebase/role_shadow_reading"

# The Ruby runtime's shadow of the role rule: a role-gated command dispatched with no caller is
# logged as `would_refuse_role` in the Rust host's wording and still runs, and the static report
# lists every command and reaction such a caller would be refused once refusal is on.
RSpec.describe Hecks::Runtime::RoleShadow do
  def self.pizzas_dir = File.expand_path("../examples/pizzas/bluebook", __dir__)

  def pizzas = @pizzas ||= Hecks.boot(self.class.pizzas_dir)

  def pizza_args
    { name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }
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
    described_class.install(:off)
    described_class.write_to(nil)
  end

  def outside_reaction
    reacting = Thread.current[:hecks_reacting]
    Thread.current[:hecks_reacting] = nil
    yield
  ensure
    Thread.current[:hecks_reacting] = reacting
  end

  def create_pizza = pizzas.dispatch_flat("Pizzas::Order.CreatePizza", **pizza_args)

  def gated_command = Struct.new(:hecks_name, :role_set).new("CreatePizza", ["Chef"])

  describe ".parse" do
    it "reads shadow and enforce as shadow, and anything else as off" do
      expect(%w[shadow ENFORCE off nonsense].map { |word| described_class.parse(word) } + [described_class.parse(nil)])
        .to eq(%i[shadow shadow off off off])
    end
  end

  describe "a role-gated command dispatched with no caller" do
    it "logs the host's line under shadow and still runs the command", :aggregate_failures do
      lines = lines_under(:shadow) { expect(create_pizza.events.map(&:name)).to eq(["PizzaCreated"]) }
      expect(lines).to eq([{ "level" => "error", "msg" => "would_refuse_role", "verb" => "Pizzas::Order.CreatePizza",
                             "role" => "Anonymous", "actor_id" => nil, "refusals" => lines.first["refusals"] }])
      expect(lines.first["refusals"].first).to include("kind" => "Unauthorized")
    end

    it "logs nothing when the mode is off" do
      expect(lines_under(:off) { create_pizza }).to be_empty
    end

    it "logs nothing for a caller that states the role" do
      expect(lines_under(:shadow) { Hecks.as_caller(role: "Chef") { create_pizza } }).to be_empty
    end
  end

  describe "a reaction" do
    it "logs the host-internal shape with origin reaction" do
      lines = lines_under(:shadow) { Hecks::Runtime::Caller.reaction { described_class.note(gated_command, "P::O.C") } }
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
    def report = @report ||= described_class.of_directory(self.class.pizzas_dir)

    it "lists each role-gated command with its roles" do
      expect(report).to include("command    Pizzas::Order.CreatePizza roles: Chef")
    end

    it "lists a policy whose target is role-gated" do
      expect(report).to match(/^reaction   Pizzas::OnPizzaPaymentReceived on .+ -> Pizzas::Order\.Purchase roles: Customer$/)
    end

    it "counts what it lists in its heading" do
      expect(report.lines.first).to include("role-gated commands, 1 reactions to one, 0 unresolved targets")
    end
  end

  describe Hecks::Adapters::Codebase::RoleShadowReading do
    it "refuses a record that names no directory" do
      expect { described_class.call(domain: { value: "" }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /name a domain/)
    end
  end
end
