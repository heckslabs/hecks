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
# Compares `instances`, `events`, AND full refusal wording (`verb` +
# `error`, not just `verb`) — the two gaps that used to make exact
# `events`/wording comparison the wrong bar here are both closed now
# (0021): `Event.payload` used to be the router's raw, unfiltered args
# (0013's own `stamp_payload`) with no post-coercion default-fill —
# `Json::overlay` (json.rs) now merges the raw args with the typed args
# struct's OWN `to_json()`, matching Ruby's own coerced-hash payload; and
# `GivenNotMet`/`EnsuresNotMet` refusal wording now carries the same
# `"{command} refused — {description}"` prefix Ruby's own
# `CommandRules::Admissibility` raises with. Both fixtures below are
# picked/maintained specifically to stay clear of the OTHER refusal-
# wording templates this generator still doesn't match byte-for-byte
# (LifecycleRefused's `transition_blocked`, the general VO-`invariant`
# message, `one_of` closed-set membership, entity-element-missing —
# `rust/project.rb`'s own header names these as a real, separate,
# deliberately out-of-scope gap) — a NEW fixture that exercises one of
# those will legitimately fail here until that gap is closed too, the
# same way any pinned fixture needs verifying before it's added.
RSpec.describe "Rust conformance (native binary)" do
  RUST_CONFORMANCE_FIXTURES = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/rust_conformance/*.json")).sort

  def native_rust_binary
    %w[release debug]
      .map { |profile| File.join(InMemoryDomain::ROOT, "rust/target/#{profile}/rust") }
      .find { |path| File.executable?(path) }
  end

  RUST_CONFORMANCE_FIXTURES.each do |fixture_path|
    it "#{File.basename(fixture_path)}: instances, events, and refusals match Ruby exactly" do
      binary = native_rust_binary
      skip "no native rust binary built — run `cd rust && cargo build` first" unless binary

      fixture = JSON.parse(File.read(fixture_path))
      domain  = fixture.fetch("domain")
      steps   = fixture.fetch("steps")

      ruby_result = Hecksagain::Fuzzing::Replay.call(domain, steps)
      ruby_instances = ruby_result[:instances].transform_values { |state| JSON.parse(JSON.generate(state)) }
      ruby_events = JSON.parse(JSON.generate(ruby_result[:events]))
      ruby_refusals = ruby_result[:refusals].map { |r| { "verb" => r[:verb].to_s, "error" => r[:error] } }

      stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
      expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"

      rust_output = JSON.parse(stdout)

      expect(rust_output["instances"]).to eq(ruby_instances)
      expect(rust_output["events"]).to eq(ruby_events)
      expect(rust_output["refusals"]).to eq(ruby_refusals)
    end
  end
end
