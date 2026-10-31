require "spec_helper"
require "hecks/cli"

# `--plan` lists what a command would write and announce, and writes nothing. It runs the same
# in-memory pipeline as `dry_run?`, so a refusal the real run would give is the refusal it shows.
RSpec.describe "--plan" do
  let(:runtime) { boot_in_memory }
  let(:runner) { Hecks::Adapters::Driving::CliRunner }

  def answer(*argv) = runner.call(runtime: runtime, argv: argv, program: "hecks")
  def create = ["order.create_pizza", "name=C", "pizza.price_cents.cents=900", "pizza.size.value=large"]

  it("lists the write and the event") do
    text, status = answer(*create, "--plan")
    expect([status, text]).to match([0, /would write Order.*\n.*would emit/m])
  end

  it("leaves the store empty, so a real create still succeeds") do
    answer(*create, "--plan")
    expect(answer(*create).last).to eq(0)
  end

  it("refuses --plan on a query with usage") do
    expect(answer("query", "order.nope", "--plan").last).to eq(2)
  end
end
