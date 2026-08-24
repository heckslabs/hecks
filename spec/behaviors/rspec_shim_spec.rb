require "hecks/behaviors/rspec"

RSpec.describe "Hecks::Behaviors::RSpec.describe_file" do
  def fixture(name) = File.join(File.expand_path("fixtures", __dir__), name)

  it "names one example per test, by the test's own description" do
    group = Hecks::Behaviors::RSpec.describe_file(fixture("pizzas_edge_cases.behaviors"))

    expect(group.examples.map(&:description)).to eq(
      Hecks::Behaviors.parse(fixture("pizzas_edge_cases.behaviors")).suite.tests.map(&:description)
    )
  end

  it "turns a parse error into one example naming the problem" do
    group = Hecks::Behaviors::RSpec.describe_file(fixture("no_loads.behaviors"))

    expect(group.examples.map(&:description)).to eq(["loads without a parse error"])
  end
end
