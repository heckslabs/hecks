require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/lifecycle_needs_attribute"

RSpec.describe RuboCop::Cop::Hecks::LifecycleNeedsAttribute do
  include_context "with a Hecks cop under test"

  it "flags a lifecycle whose aggregate declares no attribute of that name" do
    expect_offense(<<~RUBY)
      aggregate "Order" do
        lifecycle :status, default: "open" do
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `lifecycle :status` has no state to hold: `Order` declares no `attribute :status`. Declare the attribute the lifecycle tracks.
        end
      end
    RUBY
  end

  it "does not flag a lifecycle with its attribute declared on the aggregate" do
    expect_no_offenses(<<~RUBY)
      aggregate "Order" do
        attribute :status, String
        lifecycle :status, default: "open" do
        end
      end
    RUBY
  end
end
