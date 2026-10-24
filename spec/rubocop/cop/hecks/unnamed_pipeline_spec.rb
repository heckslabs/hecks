require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/unnamed_pipeline"

RSpec.describe RuboCop::Cop::Hecks::UnnamedPipeline do
  include_context "with a Hecks cop under test"

  it "flags a chain of more than three calls" do
    expect_offense(<<~RUBY)
      error.message.lines.first.to_s
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ This chain runs 4 calls; a reader has to replay each one to learn what it makes. Extract it into a method named for the result.
    RUBY
  end

  it "counts a call that carries a block" do
    expect_offense(<<~RUBY)
      rows.select { |row| row }.map(&:name).sort.join
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ This chain runs 4 calls; a reader has to replay each one to learn what it makes. Extract it into a method named for the result.
    RUBY
  end

  it "does not flag three calls" do
    expect_no_offenses("text.to_s.strip.empty?")
  end

  it "flags only the outermost call of the chain" do
    expect_offense(<<~RUBY)
      a.b.c.d.e
      ^^^^^^^^^ This chain runs 4 calls; a reader has to replay each one to learn what it makes. Extract it into a method named for the result.
    RUBY
  end
end
