require "spec_helper"

# Backstop for a name outside the closed comparator set that
# spec/categories/query_comparator_kinds_spec.rb covers: it must be refused, not silently compared
# for equality.
RSpec.describe "Comparison.holds?, an unrecognized comparator" do
  it "refuses rather than silently comparing for equality" do
    expect do
      Hecks::QuerySpecification::Common::Comparison.holds?("starts_with", "abc", "a")
    end.to raise_error(Hecks::Runtime::WiringError, /no comparator handles "starts_with"/)
  end
end
