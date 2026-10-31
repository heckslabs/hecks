require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/value_object_shorthand"

RSpec.describe RuboCop::Cop::Hecks::ValueObjectShorthand do
  include_context "with a Hecks cop under test"

  def single_value_block
    <<~RUBY
      value_object "EmailAddress" do
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^ `value_object "EmailAddress"` holds one value with no invariant, so declare it as `value_object "EmailAddress", String`.
        attribute :value, String
      end
    RUBY
  end

  it "flags a single-value block with no invariant" do
    expect_offense(single_value_block)
  end

  def block_with_invariant
    <<~RUBY
      value_object "Flag" do
        attribute :value, String
        invariant("a flag is yes or no") { value == "yes" || value == "no" }
      end
    RUBY
  end

  it "does not flag a block with an invariant" do
    expect_no_offenses(block_with_invariant)
  end

  it "does not flag a block whose single attribute is not called value" do
    expect_no_offenses(<<~RUBY)
      value_object "SchoolYear" do
        attribute :label, String
      end
    RUBY
  end

  it "does not flag the shorthand itself" do
    expect_no_offenses('value_object "EmailAddress", String')
  end
end
