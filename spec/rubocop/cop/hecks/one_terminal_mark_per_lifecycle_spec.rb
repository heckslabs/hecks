require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/one_terminal_mark_per_lifecycle"

RSpec.describe RuboCop::Cop::Hecks::OneTerminalMarkPerLifecycle do
  include_context "with a Hecks cop under test"

  it "flags a second mark :terminal line in one lifecycle" do
    expect_offense(<<~RUBY)
      lifecycle :status, default: "open" do
        mark :terminal, "closed"
        mark :terminal, "void"
        ^^^^^^^^^^^^^^^^^^^^^^ A lifecycle takes one `mark :terminal` line. Name every terminal state on that line, as `mark :terminal, "a", "b"`.
      end
    RUBY
  end

  it "does not flag one line naming every terminal state" do
    expect_no_offenses(<<~RUBY)
      lifecycle :status, default: "open" do
        mark :terminal, "closed", "void"
      end
    RUBY
  end
end
