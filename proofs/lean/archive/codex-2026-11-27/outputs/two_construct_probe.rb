require "json"
require "tmpdir"
require "fileutils"
require "hecks"
require "hecks/runtime/step_run"

source = ENV.fetch("HECKS_SOURCE", "/Users/christopheryoung/Projects/hecks")
Dir.mktmpdir("crystal-two-construct-") do |sandbox|
  FileUtils.cp_r(File.join(source, "examples/pizzas"), File.join(sandbox, "pizzas"))
  runtime = Hecks.boot(File.join(sandbox, "pizzas/bluebook"))
  rows = []
  dispatch = lambda do |label, verb, role, args|
    before = runtime.events.length
    outcome = nil
    begin
      result = Hecks.as_caller(role: role) { runtime.dispatch_flat(verb, **args) }
      outcome = { kind: "success", state: result.instance&.state }
    rescue Hecks::Refused => e
      outcome = { kind: "refusal", code: e.code, stage: e.stage, message: e.message }
    rescue StandardError => e
      outcome = { kind: "failure", class: e.class.name, message: e.message }
    end
    rows << { case: label, outcome: outcome,
              new_events: runtime.events.drop(before).map(&:name),
              instance_keys: Hecks::StepRun.instances(runtime).keys.sort }
  end

  pizza = { price_cents: { cents: 1200 }, size: { value: "large" } }
  create = "Pizzas::Order.CreatePizza"
  dispatch.call("valid_create", create, "Chef", { name: { value: "First" }, pizza: pizza })
  dispatch.call("blank_name", create, "Chef", { name: { value: "" }, pizza: pizza })
  dispatch.call("duplicate_name", create, "Chef", { name: { value: "First" }, pizza: pizza })
  dispatch.call("wrong_role", create, "Customer", { name: { value: "Second" }, pizza: pizza })
  dispatch.call("valid_after_refusals", create, "Chef", { name: { value: "Second" }, pizza: pizza })

  # Independent candidate syntax: pure guard and total state/effect change.
  guard = ->(test) { [:guard, test] }
  change = ->(update) { [:change, update] }
  atoms = [
    guard.call(->(s) { ["type_mismatch", "arguments"] if s[:name].empty? }),
    guard.call(->(s) { ["unauthorized", "role"] unless s[:role] == "Chef" }),
    guard.call(->(s) { ["already_exists", "state"] if s[:records].include?(s[:name]) }),
    change.call(->(s) { [s.merge(records: s[:records] + [s[:name]]), ["PizzaCreated"]] })
  ]
  model_records = []
  inputs = [["Chef", "First"], ["Chef", ""], ["Chef", "First"],
            ["Customer", "Second"], ["Chef", "Second"]]
  parity = rows.zip(inputs).map do |observed, (role, name)|
    state = { role: role, name: name, records: model_records }
    effects = []
    model_outcome = { kind: "success" }
    atoms.each do |type, function|
      if type == :guard
        if (refusal = function.call(state))
          model_outcome = { kind: "refusal", code: refusal[0], stage: refusal[1] }
          break
        end
      else
        state, emitted = function.call(state)
        effects.concat(emitted)
      end
    end
    model_records = state[:records]
    actual = observed[:outcome]
    raise "status mismatch: #{observed[:case]}" unless model_outcome[:kind] == actual[:kind]
    if model_outcome[:kind] == "refusal"
      raise "refusal mismatch: #{observed[:case]}" unless
        model_outcome[:code] == actual[:code] && model_outcome[:stage] == actual[:stage].to_s
    end
    raise "effect mismatch: #{observed[:case]}" unless effects == observed[:new_events]
    expected_keys = model_records.map { |record| "Pizzas::Order##{record}" }.sort
    raise "record mismatch: #{observed[:case]}" unless expected_keys == observed[:instance_keys]
    { case: observed[:case], matched: true }
  end
  puts JSON.pretty_generate({ observations: rows, two_construct_parity: parity })
end
