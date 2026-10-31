require "spec_helper"
require "hecks/cli"

# Each refusal the launcher prints leads with a stable code, so a script branches on the code and
# not on wording. The codes are the refusal classes' own names in snake case; the runner runs
# in-process against the pizzas domain, as the exit-status spec does.
RSpec.describe "refusal codes" do
  let(:runtime) { boot_in_memory }
  let(:runner) { Hecks::Adapters::Driving::CliRunner }

  def answer(*argv) = runner.call(runtime: runtime, argv: argv, program: "hecks")
  def create(name) = answer("order.create_pizza", "name=#{name}", "pizza.price_cents.cents=900", "pizza.size.value=large")
  def purchase(id) = answer("order.purchase", "id=#{id}", "customer_name=Chris", "amount.cents=900")

  it("names a missing record") { expect(purchase("nope").first).to start_with("[not_found] ") }

  it "names a repeated create" do
    create("C")
    expect(create("C").first).to start_with("[already_exists] ")
  end

  it("names an unknown command") do
    expect(answer("order.nope").first).to start_with("[unknown_command] ")
  end

  it("names an unknown query") do
    expect(answer("query", "order.nope").first).to start_with("[unknown_query] ")
  end

  it("keeps the domain's wording after the code") do
    expect(purchase("nope").first).to include("no Order with")
  end
end
