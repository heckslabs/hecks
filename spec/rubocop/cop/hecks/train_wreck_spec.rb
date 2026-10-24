require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/train_wreck"

RSpec.describe RuboCop::Cop::Hecks::TrainWreck do
  include_context "with a Hecks cop under test"

  it "flags reaching through a collaborator into another object" do
    expect_offense(<<~RUBY)
      runtime.registry.bluebooks
      ^^^^^^^^^^^^^^^^^^^^^^^^^^ `runtime.registry.bluebooks` reaches through `registry` into an object it was not handed. Ask `runtime` for it with a method named for what you want.
    RUBY
  end

  it "flags the reach when a conversion follows it" do
    expect_offense(<<~RUBY)
      attribute.type.target_name.to_s
      ^^^^^^^^^^^^^^^^^^^^^^^^^^ `attribute.type.target_name` reaches through `type` into an object it was not handed. Ask `attribute` for it with a method named for what you want.
    RUBY
  end

  it "does not flag one reader on the object it holds" do
    expect_no_offenses("runtime.bluebooks.values.first")
  end

  it "does not flag conversions and predicates" do
    expect_no_offenses("error.class.name.to_s.empty?")
  end

  it "does not flag a reader that takes arguments" do
    expect_no_offenses("registry.bluebook(name).aggregate(other)")
  end
end
