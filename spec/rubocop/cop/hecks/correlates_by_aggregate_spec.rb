require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/correlates_by_aggregate"

RSpec.describe RuboCop::Cop::Hecks::CorrelatesByAggregate do
  include_context "with a Hecks cop under test"

  it "flags an aggregate's id named by a quoted dotted path" do
    expect_offense(<<~RUBY)
      correlates_by "Message.id"
                    ^^^^^^^^^^^^ `correlates_by "Message.id"` names the aggregate's id by a dotted path. A bare aggregate name correlates by its identity, so write `correlates_by Message`.
    RUBY
  end

  it "flags an aggregate's id named by a symbol path" do
    expect_offense(<<~RUBY)
      correlates_by :"Message.id"
                    ^^^^^^^^^^^^^ `correlates_by "Message.id"` names the aggregate's id by a dotted path. A bare aggregate name correlates by its identity, so write `correlates_by Message`.
    RUBY
  end

  it "does not flag the bare aggregate name" do
    expect_no_offenses("correlates_by Message")
  end

  it "does not flag a dotted path into a field" do
    expect_no_offenses('correlates_by :"widget.id"')
  end
end
