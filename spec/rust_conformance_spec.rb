require "json"
require "open3"
require "hecksagain/fuzzing"

# THE RUST DIFFERENTIAL HARNESS, WIRED IN — bin/rust_conformance's own
# header comment used to say plainly that nothing did this ("this tool
# does not invoke Rust itself... until then, 'give me a JSON file to
# compare against' is the whole interface"). 0012 gave it a `native` mode
# that actually runs a compiled artifact; this is that mode, run as part
# of the same `bundle exec rspec` both `.githooks/pre-push` and CI already
# require — no separate CI step needed beyond building the binary first
# (`.github/workflows/ci.yml`), the same "provision it for real, don't
# skip" discipline that workflow already holds Postgres/SQLite to.
#
# Compares `instances` and `refusals` ONLY, not `events` — two real,
# documented, PRE-EXISTING gaps (0013's own Consequences) make exact event
# comparison the wrong bar here: `Event.payload` is the router's raw,
# unfiltered args (0013's own `stamp_payload`), not Ruby's
# post-value-coercion hash, so a value object field filled from a
# TARGET-type default (`PositiveMoney.currency`) shows up in Ruby's event
# payload and not Rust's; and `GivenNotMet` refusal wording lacks Ruby's
# command-name prefix (0012's own Consequences). Both are cosmetic —
# `instances` (the actual state every command/entity-command/policy/saga
# leg produces) and `refusals` (which verbs got refused) are the real
# regression signal, and neither carries either gap.
RSpec.describe "Rust conformance (native binary)" do
  RUST_CONFORMANCE_FIXTURES = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/rust_conformance/*.json")).sort

  def native_rust_binary
    %w[release debug]
      .map { |profile| File.join(InMemoryDomain::ROOT, "rust/target/#{profile}/rust") }
      .find { |path| File.executable?(path) }
  end

  RUST_CONFORMANCE_FIXTURES.each do |fixture_path|
    it "#{File.basename(fixture_path)}: instances and refusals match Ruby exactly" do
      binary = native_rust_binary
      skip "no native rust binary built — run `cd rust && cargo build` first" unless binary

      fixture = JSON.parse(File.read(fixture_path))
      domain  = fixture.fetch("domain")
      steps   = fixture.fetch("steps")

      ruby_result = Hecksagain::Fuzzing::Replay.call(domain, steps)
      ruby_instances = ruby_result[:instances].transform_values { |state| JSON.parse(JSON.generate(state)) }
      ruby_refusal_verbs = ruby_result[:refusals].map { |r| r[:verb] }

      stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
      expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"

      rust_output = JSON.parse(stdout)

      expect(rust_output["instances"]).to eq(ruby_instances)
      expect(rust_output["refusals"].map { |r| r["verb"] }).to eq(ruby_refusal_verbs)
    end
  end
end
