require "rubocop"

# Runs `.rubocop_bluebook.yml` over every bluebook, so the declaration cops hold for them in the
# gate's rspec step. A bluebook's general Ruby style is not checked here; see that config.
RSpec.describe "bluebook declarations" do
  it "has no offenses under the bluebook cops" do
    status = RuboCop::CLI.new.run(["--config", ".rubocop_bluebook.yml", "--format", "quiet", "."])
    expect(status).to eq(0)
  end
end
