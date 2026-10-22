require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/raw_shell_interpolation"

RSpec.describe RuboCop::Cop::Hecks::RawShellInterpolation do
  include_context "with a Hecks cop under test"

  let(:msg_for) do
    lambda do |call|
      "`#{call}` runs a string with `\#{}` interpolated into it, so the shell re-parses the value. " \
        "Pass the command as separate arguments (`#{call}(\"cmd\", arg)`), or wrap the value in `Shellwords.escape`."
    end
  end

  # A value with a space or a metacharacter changes the command the shell runs.
  it "flags system with one interpolated string" do
    expect_offense(<<~RUBY)
      system("git checkout \#{branch}")
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ #{msg_for.call("system")}
    RUBY
  end

  it "flags Open3.capture2e with one interpolated string" do
    expect_offense(<<~RUBY)
      Open3.capture2e("ls \#{dir}")
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ #{msg_for.call("capture2e")}
    RUBY
  end

  it "flags an interpolated command after a leading env hash" do
    expect_offense(<<~RUBY)
      system({ "A" => "1" }, "run \#{x}")
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ #{msg_for.call("system")}
    RUBY
  end

  it "flags an interpolated backtick command" do
    expect_offense(<<~RUBY)
      `git -C \#{root} status`
      ^^^^^^^^^^^^^^^^^^^^^^^ A backtick or `%x` command with `\#{}` interpolated into it is re-parsed by the shell. Use `IO.popen(["cmd", arg], &:read)` or `Open3.capture2("cmd", arg)`, or wrap the value in `Shellwords.escape`.
    RUBY
  end

  it "does not flag the argv form" do
    expect_no_offenses('system("git", "checkout", branch)')
  end

  it "does not flag a command with no interpolation" do
    expect_no_offenses('system("git status")')
  end

  it "does not flag an interpolation wrapped in Shellwords.escape" do
    expect_no_offenses(<<~'RUBY')
      system("rm #{Shellwords.escape(dir)}")
    RUBY
  end

  it "does not flag interpolation in an unrelated method named system" do
    expect_no_offenses(<<~'RUBY')
      thing.system("x #{y}")
    RUBY
  end
end
