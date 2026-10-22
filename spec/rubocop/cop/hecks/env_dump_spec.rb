require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/env_dump"

RSpec.describe RuboCop::Cop::Hecks::EnvDump do
  include_context "with a Hecks cop under test"

  # The whole environment carries every secret the process holds.
  it "flags printing the whole environment" do
    expect_offense(<<~RUBY)
      puts ENV.to_h
      ^^^^^^^^^^^^^ This prints the whole environment, which carries every secret the process holds. Print only the variable names you need.
    RUBY
  end

  it "flags a secret variable interpolated into a string" do
    expect_offense(<<~'RUBY')
      warn "using #{ENV.fetch("API_TOKEN")}"
                  ^^^^^^^^^^^^^^^^^^^^^^^^^ `ENV.fetch("API_TOKEN")` is a secret read into a string, so it will land in a log line or a message. Pass it straight to the call that needs it instead of interpolating it.
    RUBY
  end

  it "does not flag restoring the environment in a spec" do
    expect_no_offenses("saved = ENV.to_h")
  end

  it "does not flag a secret passed straight to a call" do
    expect_no_offenses('headers["Authorization"] = ENV.fetch("API_TOKEN")')
  end

  it "does not flag interpolating a variable that is not a secret" do
    expect_no_offenses(<<~'RUBY')
      puts "home is #{ENV["HOME"]}"
    RUBY
  end
end
