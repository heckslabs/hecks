require "json"
require "fileutils"
require "hecks"
require "hecks/fuzzing"

root = ENV.fetch("HECKS_SOURCE")
destination = File.expand_path("../outputs/boundary-regressions", __dir__)
FileUtils.mkdir_p(destination)

cases = {
  "authorization_min" => ["environment_caller_role", [1], "One valid Open with a stated wrong role; authorization precedes reference lookup and save."],
  "projection_refresh_min" => ["given_first_failure_wins", [0, 1, 2], "Register, Open, Suspend: the suspension policy freezes the account and its save refreshes customer_status."],
  "policy_binding_min" => ["policy_with_reads_emitter_id", [0], "One Stock emits an event; its policy binds the whole composite emitter ID into Register.Note."],
  "reaction_order_min" => ["reaction_order_per_event", [0, 1], "Start establishes the run; Advance emits two events whose saga and policy reactions must run per event."],
  "reaction_depth_min" => ["reaction_depth_bound", [0, 1], "Light establishes the beacon; one Ping starts the depth-limited self-reaction chain."]
}

cases.each do |name, (source_name, indices, note)|
  source = JSON.parse(File.read(File.join(root, "spec/corpus/semantics", "#{source_name}.json")))
  steps = indices.map { |index| source.fetch("steps").fetch(index) }
  history = Hecks::Fuzzing::Replay.call(File.join(root, source.fetch("domain")), steps)
  expected = %i[instances events refusals].to_h { |field| [field, history.fetch(field)] }
  expected.fetch(:refusals).each { |row| row[:kind] = row.fetch(:kind).split("::").last }
  fixture = { "domain" => source.fetch("domain"), "source_fixture" => "#{source_name}.json",
              "note" => note, "steps" => steps, "expect" => expected }
  File.write(File.join(destination, "#{name}.json"), JSON.pretty_generate(fixture) + "\n")
end
