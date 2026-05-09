# spec_helper.rb
#
# [antibody-exempt: dream-study Phase 0f regression harness — drives
#  `hecks-life` from rspec ; retires when the same tests can land as
#  .behaviors files inside the corresponding bluebooks (Phase 1+)]
#
# Test harness for the dream-study Phase 0f regression suite.
# Each spec drives `hecks-life` against a tmpdir-isolated bluebook
# layout and asserts on the resulting heki rows. The harness keeps
# tests under the 1-second budget by reusing the release binary and
# pruning each tmpdir on exit.
#
# Usage:
#   require_relative "spec_helper"
#   include DreamStudy::TestHarness
#   harness = setup_harness("synapse")
#   harness.copy_bluebook(MIETTE_DIR + "/body/organs/synapse.bluebook")
#   harness.dispatch("Synapse.CreateSynapse", from: "a", to: "b", strength: 0.1)
#   row = harness.heki_latest("synapse/synapse.heki")
#   expect(row["from"]).to eq("a")

require "json"
require "open3"
require "tmpdir"
require "fileutils"

REPO_ROOT       = File.expand_path("../../../..", __dir__)
HECKS_BIN       = ENV.fetch("HECKS_BIN") {
  candidates = [
    File.join(REPO_ROOT, "hecks", "rust", "target", "release", "hecks-life"),
    "/Users/christopheryoung/Projects/hecks/rust/target/release/hecks-life",
  ]
  candidates.find { |p| File.executable?(p) } or
    raise "hecks-life not found ; build via `cd hecks/rust && cargo build --release`"
}
MIETTE_DIR = ENV.fetch("MIETTE_DIR") {
  ["/Users/christopheryoung/Projects/miette", File.expand_path("../../..", __dir__)]
    .find { |p| File.directory?(File.join(p, "body")) } or
    raise "miette repo not found ; set MIETTE_DIR"
}

module DreamStudy
  # Harness — one isolated dispatch environment.
  #
  # Wraps a tmpdir with `aggregates/` + `information/`. Copies the
  # bluebooks the test cares about, dispatches commands via hecks-life,
  # reads heki rows back as parsed JSON. Each spec creates a fresh
  # harness so suites are order-independent.
  class Harness
    attr_reader :root, :agg_dir, :info_dir

    def initialize(label)
      @root     = Dir.mktmpdir("regression-#{label}-")
      @agg_dir  = File.join(@root, "aggregates")
      @info_dir = File.join(@root, "information")
      FileUtils.mkdir_p(@agg_dir)
      FileUtils.mkdir_p(@info_dir)
    end

    def copy_bluebook(path)
      FileUtils.cp(path, @agg_dir)
    end

    def dispatch(command, **attrs)
      args = [HECKS_BIN, @agg_dir, command]
      attrs.each { |k, v| args << "#{k}=#{v}" }
      stdout, stderr, status = Open3.capture3(
        { "HECKS_INFO" => @info_dir }, *args
      )
      DispatchResult.new(stdout, stderr, status.exitstatus)
    end

    # Out-of-band heki seed — uses --reason to explicitly mark this as
    # test setup. The audit log will carry that reason ; this is the
    # documented seam for seeding state without driving the full command
    # pipeline.
    def heki_seed(rel_path, **attrs)
      file = File.join(@info_dir, rel_path)
      FileUtils.mkdir_p(File.dirname(file))
      args = [HECKS_BIN, "heki", "upsert", file, "--reason", "regression spec setup"]
      attrs.each { |k, v| args << "#{k}=#{v}" }
      _, stderr, status = Open3.capture3(*args)
      raise "heki_seed failed: #{stderr}" unless status.success?
    end

    def heki_latest(rel_path)
      file = File.join(@info_dir, rel_path)
      return {} unless File.exist?(file)
      stdout, _, status = Open3.capture3(HECKS_BIN, "heki", "read", file)
      return {} unless status.success?
      data = JSON.parse(stdout)
      return {} if data.empty?
      data.values.last
    end

    def heki_all(rel_path)
      file = File.join(@info_dir, rel_path)
      return {} unless File.exist?(file)
      stdout, _, status = Open3.capture3(HECKS_BIN, "heki", "read", file)
      return {} unless status.success?
      JSON.parse(stdout)
    end

    def cleanup
      FileUtils.rm_rf(@root)
    end
  end

  DispatchResult = Struct.new(:stdout, :stderr, :exit_status) do
    def ok?
      return false unless exit_status.zero?
      payload["ok"] == true
    end

    def payload
      @payload ||= begin
        line = stdout.lines.find { |l| l.start_with?("{") }
        line ? JSON.parse(line) : {}
      rescue JSON::ParserError
        {}
      end
    end

    def error_message
      payload["error"] || stderr.strip
    end
  end

  module TestHarness
    def setup_harness(label)
      h = Harness.new(label)
      @harnesses ||= []
      @harnesses << h
      h
    end

    def teardown_harnesses
      (@harnesses || []).each(&:cleanup)
      @harnesses = []
    end
  end
end

RSpec.configure do |config|
  config.include DreamStudy::TestHarness
  config.after(:each) { teardown_harnesses }
  config.expect_with(:rspec) { |c| c.max_formatted_output_length = 800 }
end
