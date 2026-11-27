require "json"
require "tmpdir"
require "fileutils"
require "hecks"
require "hecks/runtime/step_run"

source = ENV.fetch("HECKS_SOURCE", "/Users/christopheryoung/Projects/hecks")
Dir.mktmpdir("crystal-pipeline-") do |sandbox|
  FileUtils.cp_r(File.join(source, "lib/hecks/pipeline"), File.join(sandbox, "pipeline"))
  runtime = Hecks.boot(File.join(sandbox, "pipeline"))
  rows = []
  run = lambda do |label, name, args|
    before = runtime.events.length
    begin
      result = Hecks.as_caller(role: "System") do
        runtime.dispatch_flat("Pipeline::Passage.#{name}", **args)
      end
      outcome = { kind: "success", stage: result.instance.state[:stage] }
    rescue Hecks::Refused => e
      outcome = { kind: "refusal", code: e.code, stage: e.stage, message: e.message }
    rescue StandardError => e
      outcome = { kind: "failure", class: e.class.name, message: e.message }
    end
    rows << { case: label, outcome: outcome,
              new_events: runtime.events.drop(before).map(&:name),
              instance: Hecks::StepRun.instances(runtime)["Pipeline::Passage#p1"] }
  end
  run.call("plan", "Plan", { change: { value: "p1" } })
  run.call("push_before_land", "Push", { change: "p1", pushed: { value: "abc" } })
  run.call("land", "Land", { change: "p1" })
  run.call("push", "Push", { change: "p1", pushed: { value: "abc" } })
  run.call("verify", "Verify", { change: "p1" })

  guard = ->(test) { [:guard, test] }
  change = ->(update) { [:change, update] }
  model = { stage: nil, pushed: nil }
  programs = {
    "plan" => [change.call(->(s) { [s.merge(stage: "planned"), ["PassagePlanned"]] })],
    "push_before_land" => [
      guard.call(->(s) { ["lifecycle_refused", "state"] unless s[:stage] == "landed" }),
      change.call(->(s) { [s.merge(stage: "pushed", pushed: "abc"), ["PassagePushed"]] })
    ],
    "land" => [
      guard.call(->(s) { ["lifecycle_refused", "state"] unless %w[planned dispatched].include?(s[:stage]) }),
      change.call(->(s) { [s.merge(stage: "landed"), ["PassageLanded"]] })
    ],
    "push" => [
      guard.call(->(s) { ["lifecycle_refused", "state"] unless s[:stage] == "landed" }),
      change.call(->(s) { [s.merge(stage: "pushed", pushed: "abc"), ["PassagePushed"]] })
    ],
    "verify" => [
      guard.call(->(s) { ["lifecycle_refused", "state"] unless %w[pushed held].include?(s[:stage]) }),
      change.call(->(s) { [s.merge(stage: "verified"), ["PassageVerified"]] })
    ]
  }
  parity = rows.map do |observed|
    effects = []
    predicted = { kind: "success" }
    programs.fetch(observed[:case]).each do |type, function|
      if type == :guard
        if (refusal = function.call(model))
          predicted = { kind: "refusal", code: refusal[0], stage: refusal[1] }
          break
        end
      else
        model, emitted = function.call(model)
        effects.concat(emitted)
      end
    end
    actual = observed[:outcome]
    raise "status mismatch: #{observed[:case]}" unless predicted[:kind] == actual[:kind]
    if predicted[:kind] == "refusal"
      raise "refusal mismatch: #{observed[:case]}" unless
        predicted[:code] == actual[:code] && predicted[:stage] == actual[:stage].to_s
    end
    raise "event mismatch: #{observed[:case]}" unless effects == observed[:new_events]
    raise "stage mismatch: #{observed[:case]}" unless model[:stage] == observed[:instance][:stage]
    pushed = observed[:instance][:pushed]&.[](:value)
    raise "pushed mismatch: #{observed[:case]}" unless model[:pushed] == pushed
    { case: observed[:case], matched: true }
  end
  puts JSON.pretty_generate({ observations: rows, two_construct_parity: parity })
end
