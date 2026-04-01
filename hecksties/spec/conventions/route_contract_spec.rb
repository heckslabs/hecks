require "spec_helper"

RSpec.describe Hecks::Conventions::RouteContract do
  it { expect(described_class.form_path("pizzas", "create_pizza")).to eq("/pizzas/create_pizza/new") }
  it { expect(described_class.submit_path("pizzas", "create_pizza")).to eq("/pizzas/create_pizza/submit") }
  it { expect(described_class.index_path("pizzas")).to eq("/pizzas") }
  it { expect(described_class.show_path("pizzas")).to eq("/pizzas/show") }
  it { expect(described_class.query_path("pizzas", "by_name")).to eq("/pizzas/queries/by_name") }
  it { expect(described_class.scope_path("pizzas", "active")).to eq("/pizzas/scopes/active") }
  it { expect(described_class.spec_path("pizzas", "is_valid")).to eq("/pizzas/specifications/is_valid") }
end
