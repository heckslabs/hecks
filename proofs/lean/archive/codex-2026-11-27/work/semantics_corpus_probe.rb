require "json"
require "hecks"
require "hecks/fuzzing"

root = ENV.fetch("HECKS_SOURCE")
fixtures = Dir.glob(File.join(root, "spec/corpus/semantics/*.json")).sort
failures = []
fixtures.each do |path|
  fixture = JSON.parse(File.read(path))
  result = Hecks::Fuzzing::Replay.call(File.join(root, fixture.fetch("domain")), fixture.fetch("steps"))
  expected = fixture.fetch("expect")
  observed = {
    "refusals" => JSON.parse(JSON.generate(result.fetch(:refusals))).each { |r| r["kind"] = r["kind"]&.split("::")&.last },
    "instances" => JSON.parse(JSON.generate(result.fetch(:instances))),
    "events" => JSON.parse(JSON.generate(result.fetch(:events))).each { |e| e.delete("occurred_at") }
  }
  %w[cross_domain sagas].each do |key|
    observed[key] = JSON.parse(JSON.generate(result.fetch(key.to_sym))) if expected.key?(key)
  end
  failures << File.basename(path) unless observed == expected
end
puts JSON.pretty_generate({
  source_commit: "8a8a2699961a00c54fa6858fa5d7d52bd47d084d",
  fixture_count: fixtures.length,
  exact_matches: fixtures.length - failures.length,
  mismatches: failures
})
exit(failures.empty? ? 0 : 1)
