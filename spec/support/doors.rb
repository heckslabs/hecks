require "json"
require "rack/mock"
require "hecks/forms"
require "hecks/storehouse"
require "hecks/fuzzing"
require "hecks/projections/site/role_probe"

# The ways a caller reaches a booted domain, each driven from one replay-shaped step
# (`{"verb" => "D::A.C", "args" => {...}, "role" => ...}`) and answering the same outcome shape:
# `[:ok]`, or `[:refused, message]`. A door that resolves a command's name before dispatch
# words an unknown verb or argument its own way, so those refusals compare by outcome alone.
module Doors
  # The doors a step can be sent through; Ruby and MCP also carry the step's role.
  NAMES = %i[ruby cli mcp json].freeze

  # The doors whose request takes a caller's role.
  ROLE_DOORS = %i[ruby mcp].freeze

  # The forms app name the JSON door serves every domain under.
  FORMS_APP = "DoorEquivalence".freeze

  # The role a role-gate check calls as: one no bluebook declares.
  INTRUDER = "Door intruder".freeze

  # The refusals of an argument a dispatch would not build, raised before the role gate.
  ARGUMENT_REFUSALS = Hecks::Projections::Site::RoleProbe::ARGUMENT_REFUSALS

  module_function

  # Sends one step through one door of a booted runtime.
  #
  # @param door [Symbol] one of `NAMES`
  # @param runtime [Hecks::Runtime] the booted runtime
  # @param step [Hash] a replay step, string-keyed
  # @return [Array] `[:ok]` or `[:refused, message]`
  def call(door, runtime, step)
    public_send(:"through_#{door}", runtime, step)
  end

  # Boots a fresh in-memory copy of `domain_dir`, plays `steps` through `door`, and answers
  # each step's outcome with every stored record afterwards. A step with no role is called as
  # the role its command declares. A door that takes no role skips a step stating some other
  # role (`[:skipped]`): it has no way to say who is calling, and Ruby refuses such a step
  # without a trace, so skipping it leaves the two runs' records comparable.
  #
  # @return [Hash] `outcomes:` per step and `instances:` keyed `"Domain::Aggregate#id"`
  def play(door, domain_dir, steps)
    Hecks::Fuzzing::IsolatedBoot.call(domain_dir) do |copy|
      runtime = Hecks.boot(copy, environment: nil)
      outcomes = steps.map { |step| played(door, runtime, step) }
      { outcomes: outcomes, instances: comparable(Hecks::Fuzzing::Replay.snapshot_instances(runtime)) }
    end
  end

  def played(door, runtime, step)
    declared = request_for(runtime, step).declared_role
    return [:skipped] if !ROLE_DOORS.include?(door) && step["role"] && step["role"] != declared

    call(door, runtime, declared ? { "role" => declared }.merge(step) : step)
  end

  # Records as plain data, so two boots' value objects compare by their fields.
  def comparable(instances) = JSON.parse(JSON.generate(Hecks::Runtime::Value.materialize(instances)))

  def through_ruby(runtime, step)
    args = step["args"].transform_keys(&:to_sym)
    caller_of(step) { runtime.dispatch_flat(step["verb"], **args) }
    [:ok]
  rescue *Hecks::Runtime::DOMAIN_REFUSALS, Hecks::Bluebook::Expression::EvaluationError => e
    [:refused, e.message, Hecks::Fuzzing::Replay.refusal_kind(e)]
  end

  def through_cli(runtime, step)
    argv = [cli_name(step["verb"]), *argv_pairs(request(runtime, step))]
    output, status = Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: argv)
    status.zero? ? [:ok] : [:refused, output.lines.first.to_s.strip]
  end

  def through_mcp(runtime, step)
    answer = Hecks::Storehouse.dispatch(runtime: runtime, command: cli_name(step["verb"]), summary: "door equivalence",
                                        args: request(runtime, step), role: step["role"])
    answer[:ok] ? [:ok] : [:refused, answer[:error]]
  end

  def through_json(runtime, step)
    Hecks::Forms.configure(FORMS_APP) { expose step["verb"].split("::").first }
    app = Hecks::Forms::App.for(registry: runtime.registry, app_name: FORMS_APP)
    response = Rack::MockRequest.new(app).post(json_path(step["verb"]), input: JSON.generate(request(runtime, step)),
                                                                        "CONTENT_TYPE" => "application/json")
    response.status < 300 ? [:ok] : [:refused, json_message(response)]
  end

  # One step per role-gated aggregate command the runtime holds, called as `INTRUDER`. Its args
  # are synthesized; when a synthesized zero trips a positive invariant before the role gate,
  # the step is retried with every zero raised to one, so the gate is what answers it.
  #
  # @param runtime [Hecks::Runtime] the booted runtime
  # @return [Array<Hash>] replay steps, string-keyed
  def intruder_steps(runtime)
    Hecks::Projections::Site::RoleProbe.checks(runtime.registry).map do |check|
      step = { "verb" => check.verb, "args" => plain(check.arguments), "role" => INTRUDER }
      argument_refused?(through_ruby(runtime, step)) ? step.merge("args" => raised_zeros(step["args"])) : step
    end
  end

  # Whether a Ruby outcome is a refusal of the args themselves, before the role gate.
  def argument_refused?(outcome)
    outcome.first == :refused && ARGUMENT_REFUSALS.include?(outcome.last.split("::").last)
  end

  def plain(arguments) = JSON.parse(JSON.generate(arguments))

  def raised_zeros(value)
    case value
    when Hash then value.transform_values { |inner| raised_zeros(inner) }
    when Array then value.map { |inner| raised_zeros(inner) }
    else value.is_a?(Integer) && value.zero? ? 1 : value
    end
  end

  # The bluebook the MCP door serves: the runtime's first, never an attached framework bluebook.
  def mcp_chapter(runtime) = runtime.registry.bluebooks.keys.first

  # Binds the step's role as the ambient caller for the Ruby door, or dispatches bare.
  def caller_of(step, &)
    return yield unless step["role"]

    Hecks.as_caller(role: step["role"], &)
  end

  # `box.slot.drain` for `D::Box.Slot.Drain`: the name the CLI and MCP doors resolve.
  def cli_name(verb) = verb.split("::").last.split(".").map { |word| Hecks::Naming.snake(word) }.join(".")

  def json_path(verb) = "/#{verb.sub("::", "/").tr(".", "/")}"

  def json_message(response)
    JSON.parse(response.body)["message"]
  rescue JSON::ParserError
    response.body
  end

  # The step's facts as `{to:, with:}` when its command acts on an existing record, else as given.
  def request(runtime, step) = request_for(runtime, step).to_h

  def request_for(runtime, step)
    domain, rest = step["verb"].split("::", 2)
    DoorRequest.new(runtime.registry.bluebook(domain), rest.split("."), step["args"])
  end

  # `["to=b1", "amount.cents=5"]` for `{to: "b1", with: {amount: {cents: 5}}}`.
  def argv_pairs(request)
    facts = request.key?(:with) ? request[:with] : request
    route = request.key?(:to) ? { "to" => request[:to] } : {}
    dotted(route.merge(facts))
  end

  def dotted(hash, prefix = nil)
    hash.flat_map do |key, value|
      path = [prefix, key].compact.join(".")
      value.is_a?(Hash) ? dotted(value, path) : ["#{path}=#{value}"]
    end
  end

  # One step's facts split into the receiver a door's `to:` names and the facts it carries.
  class DoorRequest
    # The `to:` a request carries when its args name no record.
    UNNAMED_RECORD = "unnamed-record".freeze

    def initialize(bluebook, path, args)
      @aggregate = bluebook&.aggregate(path.first)
      @entity    = path.size == 3 ? named(@aggregate&.entities, path[1]) : nil
      @command   = named((@entity || @aggregate)&.commands, path.last)
      @args      = args
    end

    # @return [String, nil] the role the step's command declares, nil for none or no command
    def declared_role = @command&.role.to_s.then { |role| role.empty? ? nil : role }

    # @return [Hash] `{to:, with:}` for a command with a receiver, otherwise the args unchanged
    def to_h
      return { to: entity_route, with: facts(@aggregate, @entity) } if @entity && @command
      return { to: identity(@aggregate), with: facts(@aggregate) } if receiving?

      @args
    end

    private

    def named(constructs, name) = Array(constructs).find { |construct| construct.hecks_name == name }

    def receiving? = @command && !@command.references.to_s.empty?

    def entity_route
      { aggregate: identity(@aggregate), entity: identity(@entity, value_owner: @aggregate) }
    end

    # The record the args name; a placeholder when they name none, so the door still routes
    # the request and the dispatch refuses it on its own terms.
    def identity(construct, value_owner: construct)
      Hecks::Runtime::Identity.of(construct, symbolized, value_owner: value_owner) || UNNAMED_RECORD
    end

    # The args less the identity the route carries, keeping any the command also declares.
    def facts(*constructs)
      declared = @command.attributes.map { |attribute| attribute.name.to_s }
      heads = constructs.flat_map { |construct| construct.identity_heads.map(&:to_s) } - declared
      @args.reject { |key, _| heads.include?(key.to_s) }
    end

    def symbolized = @args.transform_keys(&:to_sym)
  end
end
