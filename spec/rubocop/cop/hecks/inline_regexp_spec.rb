require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/inline_regexp"

RSpec.describe RuboCop::Cop::Hecks::InlineRegexp do
  include_context "with a Hecks cop under test"

  it "flags a pattern written inline" do
    expect_offense(<<~'RUBY')
      name.match?(/\A[a-z]+\z/)
                  ^^^^^^^^^^^^ Name this pattern: assign it to a constant that says what it matches, and use the constant here.
    RUBY
  end

  it "does not flag a pattern held by a constant" do
    expect_no_offenses('IDENTIFIER = /\A[a-z]+\z/')
  end

  it "does not flag a pattern built from a runtime value" do
    expect_no_offenses(<<~'RUBY')
      line.match?(/\A#{prefix}:/)
    RUBY
  end

  it "does not flag patterns inside a frozen constant list" do
    expect_no_offenses("SEPARATORS = [/,/, /;/].freeze")
  end
end
