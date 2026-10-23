require "spec_helper"
require "json"
require "hecks/fuzzing"

# Every mutation op, on both engines and at both levels. A command's own ops are held to Ruby
# and Rust alike through a semantics corpus fixture that dispatches them: the semantics corpus
# spec runs both against its frozen `expect`. The ops that write an entity's field are recomputed
# independently of the runtime over generated sequences and the refusal fixture's steps, and
# every one must agree.
RSpec.describe "every mutation op", :aggregate_failures do
  # The domains whose entity commands use every field-writing op between them.
  ENTITY_OP_DOMAINS = %w[spec/fixtures/entity_list_mutations qa/stress_domains/nested_pieces].freeze

  def self.root = InMemoryDomain::ROOT

  def self.vocabulary = Hecks::Vocabulary.fetch("MutationOp")

  def self.field_ops = Hecks::Bluebook::DSL::CommandBuilder::FIELD_EFFECTS.map(&:to_s)

  # The semantics fixtures that dispatch each op, keyed by op.
  def self.semantics_ops
    @semantics_ops ||= semantics_fixtures.flat_map { |name, ops| ops.map { |op| [op, name] } }
                                         .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
  end

  # Each semantics fixture's file name with the ops its steps dispatch.
  def self.semantics_fixtures
    Dir[File.join(root, "spec/corpus/semantics/*.json")].to_h do |path|
      fixture = JSON.parse(File.read(path))
      [File.basename(path), dispatched_ops(File.join(root, fixture["domain"]), fixture["steps"])]
    end
  end

  def self.dispatched_ops(domain, steps)
    bluebooks = Hecks::Runtime::Loader.describe(domain, environment: nil).registry.bluebooks
    commands = steps.filter_map { |step| command_of(bluebooks, step["verb"].to_s) }
    commands.flat_map { |command| ops_of(command) }.uniq
  end

  def self.ops_of(command) = command.mutations.map { |mutation| mutation.op.to_s }

  # The command a verb names, at aggregate or entity level, or nil when it names none.
  def self.command_of(bluebooks, verb)
    domain, rest = verb.split("::", 2)
    aggregate_name, *path = rest.to_s.split(".")
    holder = holder_of(bluebooks[domain]&.aggregate(aggregate_name), path)
    holder&.commands&.find { |command| command.hecks_name == path.last }
  end

  # The aggregate itself, or the entity a three-part verb names inside it.
  def self.holder_of(aggregate, path)
    return aggregate unless aggregate && path.size == 2

    aggregate.entities.find { |entity| entity.hecks_name == path.first }
  end

  # Every replay whose entity mutations are traced: ten seeds of each entity domain, and the
  # refusal fixture's own steps.
  def self.histories
    @histories ||= ENTITY_OP_DOMAINS.flat_map { |dir| (1..10).map { |seed| generated(File.join(root, dir), seed) } } +
                   [fixture_history]
  end

  def self.generated(dir, seed)
    Hecks::Fuzzing::Replay.call(dir, Hecks::Fuzzing::SequenceGenerator.generate(dir, seed: seed, steps: 25))
  end

  def self.fixture_history
    dir = File.join(root, "spec/fixtures/refusal_kinds")
    Hecks::Fuzzing::Replay.call(dir, JSON.parse(File.read(File.join(dir, "steps.json")))["steps"])
  end

  # The ops an accepted entity command applied, across every traced replay.
  def self.entity_ops_applied
    histories.flat_map do |history|
      history[:mutation_traces].flat_map { |trace| ops_of(command_of(history[:bluebooks], trace[:verb])) }
    end.uniq
  end

  vocabulary.each do |op|
    it "holds both engines to #{op} through a semantics fixture that dispatches it" do
      expect(self.class.semantics_ops[op]).not_to be_nil
    end
  end

  field_ops.each do |op|
    it "applies #{op} to an entity's field in a traced replay" do
      expect(self.class.entity_ops_applied).to include(op)
    end
  end

  it "agrees with the independent recompute on every entity mutation applied" do
    verdicts = self.class.histories.map { |history| Hecks::Fuzzing::Properties.mutations_match_recompute(history) }
    expect(verdicts - [true]).to be_empty
  end

  it "names every field-writing op in the vocabulary, so the loops above cover the vocabulary" do
    expect(self.class.field_ops - self.class.vocabulary).to be_empty
  end
end
