# frozen_string_literal: true

require "fileutils"
require "json"

# The one door for a spec that bounds wall-clock time. A shared CI runner is about four times
# slower than the machine a bound was written on, and its pace varies, so a timing example is
# tagged `:wall_clock`, asserts through `expect_wall_clock` and is listed in `WallClock::EXAMPLES`.
#
# - **On CI** a bound is stretched by `multiplier`; locally it holds as written.
# - **A breach** is a pending finding, not a failure (see `Expectation#expect_wall_clock`), so a
#   slow runner never fails a train, nor a landing's gate on a loaded machine.
# - **`HECKS_WALL_CLOCK_STRICT=1`** fails a breach, for a run that must catch a timing regression.
module WallClock
  # A wall-clock bound passed; the example is pending with this as its exception.
  class Breach < StandardError; end

  FINDINGS = File.expand_path("../../tmp/wall_clock_findings.jsonl", __dir__)
  CI_MULTIPLIER = 4.0

  module_function

  # @return [Float] the factor an absolute bound is stretched by on this machine
  def multiplier
    given = ENV.fetch("HECKS_WALL_CLOCK_MULTIPLIER", "")
    return Float(given) unless given.empty?

    ci? ? CI_MULTIPLIER : 1.0
  end

  # @return [Boolean] whether a breach becomes a pending finding instead of a failure
  def forgiving? = ENV.fetch("HECKS_WALL_CLOCK_STRICT", "").empty?

  # @return [Boolean] whether this run is on CI
  def ci? = !ENV.fetch("CI", "").empty?

  # @param bound [Numeric] the bound as written
  # @param stretched [Boolean] whether the runner's pace may stretch the bound
  # @return [Float] the bound this run holds the measurement to
  def bound(bound, stretched:) = stretched ? bound * multiplier : bound.to_f

  # Raises unless the running example is tagged `:wall_clock`.
  # @param example [RSpec::Core::Example, nil] the running example
  # @return [void]
  def refuse_untagged!(example)
    return if example&.metadata&.fetch(:wall_clock, false)

    raise ArgumentError, "expect_wall_clock needs the :wall_clock tag on #{example&.location || "its example"}"
  end

  # @param example [RSpec::Core::Example] the example that breached
  # @param measured [Numeric] what was measured
  # @param bound [Numeric] the bound it passed
  # @return [String] the breach, said in one line
  def said(example, measured, bound)
    "wall-clock breach at #{example.location}: #{measured.round(4)} is not under " \
      "#{bound.round(4)} (multiplier #{multiplier})"
  end

  # Appends one finding line; a file that cannot be written leaves the pending message alone.
  # @param example [RSpec::Core::Example] the example that breached
  # @param message [String] the breach
  # @return [void]
  def file_finding(example, message)
    FileUtils.mkdir_p(File.dirname(FINDINGS))
    line = { example: example.full_description, location: example.location, said: message }
    File.open(FINDINGS, "a") { |file| file.puts(JSON.generate(line)) }
  rescue SystemCallError
    nil
  end

  # The matcher side, mixed into every example group.
  module Expectation
    # Asserts a wall-clock measurement stays under a bound. A breach marks the example pending
    # with the breach as its pending exception, so `CiSkipBackstop` sees a live check, and appends
    # one JSON line to `FINDINGS`; no CI job uploads that file yet, so on a runner the finding
    # lives in the pending message of the log. A bound passed `stretched: false` (a ratio
    # of two measurements on one machine, or a distance from a known slow path) is never stretched.
    # Put it last in its example: on a forgiven breach nothing after it runs.
    # @param measured [Numeric] seconds, milliseconds or a ratio, as the bound is written
    # @param under [Numeric] the bound
    # @param stretched [Boolean] whether the runner's pace may stretch the bound
    # @param said [String, Proc, nil] the failure message
    # @return [void]
    def expect_wall_clock(measured, under:, stretched: true, said: nil)
      example = RSpec.current_example
      WallClock.refuse_untagged!(example)
      bound = WallClock.bound(under, stretched: stretched)
      return expect(measured).to(be < bound, said) unless WallClock.forgiving? && measured >= bound

      forgive_breach(example, WallClock.said(example, measured, bound))
    end

    private

    def forgive_breach(example, message)
      WallClock.file_finding(example, message)
      pending(message)
      raise WallClock::Breach, message
    end
  end
end

RSpec.configure { |config| config.include WallClock::Expectation }
