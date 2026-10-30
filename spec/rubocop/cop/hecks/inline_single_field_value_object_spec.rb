require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/inline_single_field_value_object"

RSpec.describe RuboCop::Cop::Hecks::InlineSingleFieldValueObject do
  include_context "with a Hecks cop under test"

  MESSAGE = "A value object whose only line is `attribute :value, Integer` is declared by the " \
            "shorthand `value_object \"BookCopies\", Integer`; the block adds nothing. Inline it, " \
            "or keep the block if it needs an invariant or an option.".freeze

  # A block holding only `attribute :value, Integer`: the shape the cop flags.
  BARE_BLOCK = <<~RUBY.freeze
    value_object "BookCopies" do
    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ #{MESSAGE}
      attribute :value, Integer
    end
  RUBY

  # The shorthand the bare block is rewritten to.
  SHORTHAND = "value_object \"BookCopies\", Integer\n".freeze

  it "flags a block whose only line is a typed value attribute" do
    expect_offense(BARE_BLOCK)
  end

  it "rewrites the block to the shorthand" do
    expect_offense(BARE_BLOCK)
    expect_correction(SHORTHAND)
  end

  # A block whose invariant the shorthand cannot carry.
  WITH_INVARIANT = <<~RUBY.freeze
    value_object "BookCopies" do
      attribute :value, Integer
      invariant("a copy count is not negative") { value >= 0 }
    end
  RUBY

  it "leaves a block with an invariant alone" do
    expect_no_offenses(WITH_INVARIANT)
  end

  it "leaves a block whose attribute carries an option alone" do
    expect_no_offenses(<<~RUBY)
      value_object "BookCopies" do
        attribute :value, Integer, default: 1
      end
    RUBY
  end

  it "leaves a block that declares a field other than value alone" do
    expect_no_offenses(<<~RUBY)
      value_object "Address" do
        attribute :street, String
      end
    RUBY
  end

  it "leaves the shorthand itself alone" do
    expect_no_offenses(SHORTHAND)
  end
end
