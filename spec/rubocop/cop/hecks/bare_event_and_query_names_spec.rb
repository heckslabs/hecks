require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/bare_event_and_query_names"

RSpec.describe RuboCop::Cop::Hecks::BareEventAndQueryNames do
  include_context "with a Hecks cop under test"

  it "flags a dotted event name passed to starts_on" do
    expect_offense(<<~RUBY)
      starts_on "Message.Sent"
                ^^^^^^^^^^^^^^ `"Message.Sent"` names an event or query by its string. Name it by its constant, `Message::Sent`, so a misspelling fails at load.
    RUBY
  end

  it "flags a bare event name passed to on" do
    expect_offense(<<~RUBY)
      on "Sent"
         ^^^^^^ `"Sent"` names an event or query by its string. Name it by its constant, `Sent`, so a misspelling fails at load.
    RUBY
  end

  it "flags a capitalised transition key" do
    expect_offense(<<~RUBY)
      transition "Churn" => "churned", from: "active"
                 ^^^^^^^ `"Churn"` names an event or query by its string. Name it by its constant, `Churn`, so a misspelling fails at load.
    RUBY
  end

  it "does not flag the constant form" do
    expect_no_offenses(<<~RUBY)
      starts_on Message::Sent
      transition Churn => "churned", from: "active"
    RUBY
  end
end
