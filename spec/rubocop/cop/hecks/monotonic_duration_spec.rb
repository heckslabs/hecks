require_relative "../../../support/cop_spec_context"
require_relative "../../../../lib/rubocop/cop/hecks/monotonic_duration"

RSpec.describe RuboCop::Cop::Hecks::MonotonicDuration do
  include_context "with a Hecks cop under test"

  # A wall-clock subtraction can go negative when the clock steps.
  it "flags Time.now minus a local" do
    expect_offense(<<~RUBY)
      started = Time.now
      elapsed = Time.now - started
                ^^^^^^^^^^^^^^^^^^ `Time.now - started` measures elapsed time on the wall clock, which can step. Take both ends from `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.
    RUBY
  end

  it "flags Time.now.to_f minus an instance variable" do
    expect_offense(<<~RUBY)
      @started = Time.now.to_f
      Time.now.to_f - @started
      ^^^^^^^^^^^^^^^^^^^^^^^^ `Time.now - @started` measures elapsed time on the wall clock, which can step. Take both ends from `Process.clock_gettime(Process::CLOCK_MONOTONIC)`.
    RUBY
  end

  # `Time.now - seconds` is a past timestamp, not an elapsed time.
  it "does not flag subtracting a plain number of seconds" do
    expect_no_offenses(<<~RUBY)
      seconds = 3600
      File.utime(Time.now - seconds, Time.now - seconds, path)
    RUBY
  end

  it "does not flag an age against a file's stored mtime" do
    expect_no_offenses("Time.now - File.mtime(path) > KEEP")
  end

  it "does not flag a monotonic subtraction" do
    expect_no_offenses("Process.clock_gettime(Process::CLOCK_MONOTONIC) - started")
  end
end
