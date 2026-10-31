require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/invariant_expression_language"

RSpec.describe RuboCop::Cop::Hecks::InvariantExpressionLanguage do
  include_context "with a Hecks cop under test"

  it "flags empty? in an invariant" do
    expect_offense(<<~RUBY)
      invariant("a name is present") { name.empty? }
                                       ^^^^^^^^^^^ `name.empty?` is outside the expression language, which cannot evaluate it. Spell the test out: `==` joined by `||` for a set of values, or `!= ""` for a non-empty test.
    RUBY
  end

  it "flags include? in a given" do
    expect_offense(<<~RUBY)
      given("a flag") { value.include?("yes") }
                        ^^^^^^^^^^^^^^^^^^^^^ `value.include?("yes")` is outside the expression language, which cannot evaluate it. Spell the test out: `==` joined by `||` for a set of values, or `!= ""` for a non-empty test.
    RUBY
  end

  it "flags a %w list in an invariant" do
    expect_offense(<<~RUBY)
      invariant("a flag") { %w[yes no] }
                            ^^^^^^^^^^ `%w[yes no]` is outside the expression language, which cannot evaluate it. Spell the test out: `==` joined by `||` for a set of values, or `!= ""` for a non-empty test.
    RUBY
  end

  it "does not flag a comparison joined by ||" do
    expect_no_offenses(<<~RUBY)
      invariant("a flag is yes or no") { value == "yes" || value == "no" }
    RUBY
  end

  it "does not flag a non-empty test written with !=" do
    expect_no_offenses(<<~RUBY)
      invariant("a name is present") { name != "" }
    RUBY
  end
end
