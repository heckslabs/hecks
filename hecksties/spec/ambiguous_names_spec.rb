require "spec_helper"

RSpec.describe "AmbiguousNames multi-domain warning" do
  def build_domain(name, aggregate_names)
    Hecks.domain name do
      aggregate_names.each do |agg_name|
        aggregate agg_name do
          attribute :name, String
          command "Create#{agg_name}" do
            attribute :name, String
          end
        end
      end
    end
  end

  it "warns when the same aggregate name appears in two bounded contexts" do
    d1 = build_domain("Billing", ["Invoice", "Order"])
    d2 = build_domain("Shipping", ["Shipment", "Order"])

    warnings = Hecks::MultiDomain::Validator.ambiguous_name_warnings([d1, d2])
    expect(warnings).to include(/'Order' appears in multiple bounded contexts/)
  end

  it "does not warn when aggregate names are unique across contexts" do
    d1 = build_domain("Billing", ["Invoice"])
    d2 = build_domain("Shipping", ["Shipment"])

    warnings = Hecks::MultiDomain::Validator.ambiguous_name_warnings([d1, d2])
    expect(warnings).to be_empty
  end

  it "includes all context names in the warning message" do
    d1 = build_domain("Sales", ["Product"])
    d2 = build_domain("Inventory", ["Product"])

    warnings = Hecks::MultiDomain::Validator.ambiguous_name_warnings([d1, d2])
    expect(warnings.first).to include("Sales")
    expect(warnings.first).to include("Inventory")
  end
end
