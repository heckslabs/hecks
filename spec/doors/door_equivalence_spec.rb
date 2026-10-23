require "spec_helper"
require_relative "../support/doors"

# The same action through every door gives the same outcome: Ruby, the CLI, MCP and JSON over
# the forms app each accept or refuse it alike and leave the same records. A door words a name
# it could not resolve (an unknown verb or argument, or an argv value it could not type) its own
# way, so those refusals compare by outcome alone. The forms app serves no entity command
# routes, so the JSON door is held to the steps it can address.
RSpec.describe "every door", :aggregate_failures do
  # The refusal kinds a door resolves, and words, before the dispatch is reached.
  DOOR_WORDED_KINDS = %w[UnknownVerb UnknownArgument TypeMismatch].freeze

  # A known wording gap: an entity command routed by `to:` whose entity is absent is refused as
  # NotFound with the entity's identity left blank, where Ruby names it. The outcome agrees.
  BLANK_ENTITY_IDENTITY = /\Ano \w+ with \S+  on /

  # A domain directory with the steps it is played through.
  def self.walks
    root = InMemoryDomain::ROOT
    { "refusal_kinds" => ["spec/fixtures/refusal_kinds", "spec/fixtures/refusal_kinds/steps.json"],
      "pizzas"        => ["examples/pizzas", "spec/corpus/pizzas.json"],
      "banking"       => ["examples/banking", "spec/corpus/banking.json"] }
      .transform_values { |dir, steps| [File.join(root, dir), File.join(root, steps)] }
  end

  # The command steps of a walk a door can address; the forms app has no entity route.
  def self.steps_for(door, steps_file)
    steps = JSON.parse(File.read(steps_file))["steps"].select { |step| step["verb"] }
    door == :json ? steps.reject { |step| step["verb"].split("::").last.count(".") > 1 } : steps
  end

  # Each step where `door` and Ruby disagree, as one line naming the step and both outcomes.
  def disagreements(door, ruby, other)
    ruby[:outcomes].zip(other[:outcomes]).each_with_index.filter_map do |(expected, actual), index|
      next if actual == [:skipped] || agree?(expected, actual)

      "step #{index}: ruby #{expected.inspect}, #{door} #{actual.inspect}"
    end
  end

  def agree?(expected, actual)
    return expected == actual if expected == [:ok] || actual == [:ok]

    DOOR_WORDED_KINDS.include?(expected.last.split("::").last) || expected[1] == actual[1] || unaddressed?(actual)
  end

  # A door refusal that names no record: the placeholder route, or the blank-identity gap above.
  def unaddressed?(actual) = actual[1].include?(Doors::DoorRequest::UNNAMED_RECORD) || actual[1].match?(BLANK_ENTITY_IDENTITY)

  walks.each do |name, (dir, steps_file)|
    (Doors::NAMES - [:ruby]).each do |door|
      it "gives #{name}'s steps the same outcomes and records through #{door} as through Ruby" do
        steps = self.class.steps_for(door, steps_file)
        ruby, other = [:ruby, door].map { |each| Doors.play(each, dir, steps) }
        expect(disagreements(door, ruby, other)).to be_empty
        expect(other[:instances]).to eq(ruby[:instances])
      end
    end
  end

  it "still words an absent entity's identity blank through a door that routes by to:" do
    step = Doors.play(:mcp, *self.class.walks["banking"].then { |dir, file| [dir, self.class.steps_for(:mcp, file)] })
    expect(step[:outcomes].count { |outcome| outcome[1].to_s.match?(BLANK_ENTITY_IDENTITY) }).to be_positive
  end
end
