require "json"
require "hecks"
require "hecks/fuzzing"

root = ENV.fetch("HECKS_SOURCE")
fixture = JSON.parse(File.read(File.join(root, "spec/corpus/semantics/environment_caller_role.json")))
domain = File.join(root, fixture.fetch("domain"))
prefixes = (1..fixture.fetch("steps").length).map do |length|
  result = Hecks::Fuzzing::Replay.call(domain, fixture.fetch("steps").take(length))
  { prefix: length,
    refusals: result.fetch(:refusals).map { |r| r.fetch(:kind).split("::").last },
    instance_keys: result.fetch(:instances).keys.sort,
    events: result.fetch(:events).map { |e| e.fetch(:name) } }
end
unchanged_after_wrong_roles = prefixes[0].fetch(:instance_keys) == prefixes[1].fetch(:instance_keys) &&
  prefixes[1].fetch(:instance_keys) == prefixes[2].fetch(:instance_keys) &&
  prefixes[0].fetch(:events) == prefixes[1].fetch(:events) &&
  prefixes[1].fetch(:events) == prefixes[2].fetch(:events)
allowed_role_committed = prefixes[3].fetch(:instance_keys).length == prefixes[2].fetch(:instance_keys).length + 1 &&
  prefixes[3].fetch(:events).length == prefixes[2].fetch(:events).length + 1
puts JSON.pretty_generate({ prefixes: prefixes, unchanged_after_wrong_roles: unchanged_after_wrong_roles,
                            allowed_role_committed: allowed_role_committed })
exit(unchanged_after_wrong_roles && allowed_role_committed ? 0 : 1)
