# [antibody-exempt: dream-study Phase 0g test-gate harness — drives the
#  Rust runtime from RSpec to lock i106 math invariants. Not a body
#  daemon, no production code path lives here. Future home : when the
#  Mind PR (Phase 4) lands a process_manager + first-class queries for
#  organ math, this driver retires in favour of behavior-runtime tests.]
#
# DispatchHelper — drive hecks-life from RSpec, isolated tmpdir per case.
#
# The Ruby behaviors interpreter does NOT implement the i106 math
# primitives (`multiply` / `clamp`). These tests must drive the real
# Rust runtime to validate organ math. DispatchHelper :
#
#   - mints a fresh HECKS_INFO tmpdir per call (or reusable session)
#   - seeds a heki row via `hecks-life heki append --reason ...`
#   - dispatches a command via `hecks-life <agg_dir> Aggregate.Command`
#   - returns the parsed JSON state after dispatch
#   - reads field values directly via `hecks-life heki latest-field`
#
# Usage :
#   d = DispatchHelper.new
#   d.with_isolated_info do |info_dir|
#     id = d.seed("synapse/synapse.heki", from: "A", to: "B",
#                 strength: 0.5, state: "alive", firings: 0,
#                 last_fired_at: "now")
#     result = d.dispatch("Synapse.StrengthenSynapse", synapse: id)
#     expect(result.fetch("strength").to_f).to eq(0.52)
#   end

require "json"
require "open3"
require "tmpdir"
require "fileutils"

class DispatchHelper
  MIETTE_ROOT = File.expand_path("../../../..", __dir__)
  HECKS_BIN   = File.expand_path("../hecks/rust/target/release/hecks-life",
                                 MIETTE_ROOT)
  AGG_DIR     = File.expand_path("../hecks/hecks_conception/aggregates",
                                 MIETTE_ROOT)

  attr_reader :info_dir

  def initialize(info_dir: nil)
    @info_dir = info_dir
  end

  # Run a block with an isolated HECKS_INFO tmpdir set on this helper.
  # Yields the dir path. Cleans up automatically.
  def with_isolated_info
    Dir.mktmpdir("0g_invariants_") do |dir|
      previous = @info_dir
      @info_dir = dir
      begin
        yield dir
      ensure
        @info_dir = previous
      end
    end
  end

  # Seed a row via `heki append`. relative_path is e.g.
  # "synapse/synapse.heki" — joined under @info_dir.
  # Returns the auto-generated id of the new row.
  def seed(relative_path, **fields)
    raise "no info_dir — call with_isolated_info" unless @info_dir
    full = File.join(@info_dir, relative_path)
    FileUtils.mkdir_p(File.dirname(full))
    args = ["heki", "append", full, "--reason", "0g invariants seed"]
    fields.each { |k, v| args << "#{k}=#{v}" }
    out, err, status = run(args)
    raise "heki append failed: #{err}" unless status.success?
    # latest row — grab id
    latest_field(relative_path, "id")
  end

  # Dispatch a command via the real Rust runtime. Returns the parsed
  # `state` hash from hecks-life's JSON response. Raises if dispatch
  # exited non-zero (caller can rescue to assert failures).
  def dispatch(command, **attrs)
    raise "no info_dir — call with_isolated_info" unless @info_dir
    args = [AGG_DIR, command]
    attrs.each { |k, v| args << "#{k}=#{v}" }
    out, err, status = run(args)
    raise "dispatch #{command} failed (rc=#{status.exitstatus}) : #{err}\n#{out}" \
      unless status.success?
    payload = JSON.parse(out.lines.last.to_s)
    payload.fetch("state") { raise "no state in dispatch response: #{payload.inspect}" }
  end

  # Read a single field's display string from the latest row of a heki.
  def latest_field(relative_path, field)
    full = File.join(@info_dir, relative_path)
    out, _err, status = run(["heki", "latest-field", full, field.to_s])
    raise "latest-field failed for #{field}" unless status.success?
    out.strip
  end

  # List rows as parsed JSON.
  def list(relative_path)
    full = File.join(@info_dir, relative_path)
    out, _err, status = run(["heki", "list", full, "--format", "json"])
    return [] unless status.success?
    JSON.parse(out)
  rescue JSON::ParserError
    []
  end

  # Sanity check : binary + aggregate dir present (specs skip otherwise).
  def self.ready?
    File.executable?(HECKS_BIN) && File.directory?(AGG_DIR)
  end

  def self.skip_reason
    return "hecks-life binary not built at #{HECKS_BIN}" unless File.executable?(HECKS_BIN)
    return "aggregates dir missing at #{AGG_DIR}" unless File.directory?(AGG_DIR)
    nil
  end

  private

  def run(args)
    env = { "HECKS_INFO" => @info_dir, "HECKS_DAEMON" => "1" }
    Open3.capture3(env, HECKS_BIN, *args.map(&:to_s))
  end
end
