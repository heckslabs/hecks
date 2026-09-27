require "spec_helper"

# Every verb the language declares must be offered to the judge.
#
# A rule the judge never dispatches input to cannot fire, so the expectation is
# derived from the language itself rather than a hand-kept map.
RSpec.describe "the judge's coverage of the language" do
  # Banking is the only corpus member carrying every category at once. The examples
  # dispatch through a `Spy`, never the real runtime, so one shared boot is safe.
  before(:context) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    @banking = registry.bluebook("Banking")
    # Paging is the one real chapter that calls `attaches_to`, so
    # `Bluebook::Bluebook.Attach` needs a second bluebook judged.
    @paging = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Paging")
    # Governance is the one real chapter that declares `provides "authorization"`.
    @governance = Hecks::Framework.chapter("Governance")
    # "Bluebook" (the meta-grammar) is the one real user of `Entity.Holds`; judged
    # here so that verb counts as offered.
    @grammar = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    # `Entity.Reference` is real DSL surface no corpus member nests inside a piece,
    # so a small fixture (as in relationship_declaration_spec) exercises it.
    @relationships = Hecks::Bluebook::DSL::BluebookBuilder.build("EntityRelationshipCoverage") do
      aggregate "Target" do
        identified_by { attribute :number, String }
      end

      aggregate "Holder" do
        identified_by { attribute :number, String }

        entity "Piece" do
          identified_by { attribute :sequence, Integer }

          belongs_to Target
        end
      end
    end
  end

  attr_reader :banking
  attr_reader :paging
  attr_reader :governance
  attr_reader :grammar
  attr_reader :relationships

  # Records what the judge asks for, without judging anything.
  class Spy
    attr_reader :verbs

    def initialize = @verbs = []
    def dispatch(verb, **_args) = @verbs << verb
    def registry = nil
  end

  def offered_in_order(bluebook = banking)
    spy = Spy.new
    judge = Hecks::Bluebook::MetaValidator::Judge.allocate
    judge.instance_variable_set(:@bluebook, bluebook)
    judge.instance_variable_set(:@refusals, [])
    judge.instance_variable_set(:@runtime, spy)
    judge.instance_variable_set(
      :@plan,
      Hecks::Bluebook::MetaValidator::Plan.for(Hecks::Bluebook::MetaValidator.grammar_registry)
    )
    judge.send(:judge!)
    spy.verbs
  end

  # Banking carries every query and read_model option itself, so no union with
  # another chapter is needed for `Query.Option` and `ReadModel.Option`.
  def offered_verbs
    offered_in_order + offered_in_order(paging) + offered_in_order(grammar) +
      offered_in_order(relationships) + offered_in_order(governance)
  end

  # Every command on every aggregate of the meta-domain, spelled as the judge would
  # dispatch it. Vocabulary and Syntax are excluded: Vocabulary declares no commands,
  # and Syntax is seeded by `SyntaxBoot`, never by the judge's own walk.
  META_ONLY_AGGREGATES = %w[Vocabulary Syntax].freeze

  def declared_verbs
    Hecks::Bluebook::MetaValidator.grammar_registry
                                  .bluebook("Bluebook").aggregates
                                  .reject { |aggregate| META_ONLY_AGGREGATES.include?(aggregate.hecks_name) }
                                  .flat_map { |aggregate| aggregate_verbs(aggregate) }
  end

  # Entities nest, so their commands are dotted verbs (`ValueObject.Member.Pair`,
  # `Judge#verb_for`); recursion covers pieces nested two levels deep.
  def aggregate_verbs(aggregate)
    aggregate.commands.map { |c| "Bluebook::#{aggregate.name}.#{c.hecks_name}" } +
      aggregate.entities.flat_map { |entity| entity_verbs(aggregate.name, entity) }
  end

  def entity_verbs(prefix, entity)
    dotted = "#{prefix}.#{entity.hecks_name}"
    entity.commands.map { |c| "Bluebook::#{dotted}.#{c.hecks_name}" } +
      entity.entities.flat_map { |piece| entity_verbs(dotted, piece) }
  end

  it "offers every verb the language declares" do
    missing = declared_verbs - offered_verbs

    expect(missing).to be_empty,
                       "the language declares #{missing.size} verb(s) the judge never offers, " \
                       "so every rule hanging off them is decoration:\n  #{missing.join("\n  ")}"
  end

  it "offers no verb the language does not declare" do
    # The judge swallows Runtime::UnknownVerb, so a misspelled or retired verb
    # dispatches into silence and its rules stop firing with nothing going red.
    phantom = offered_verbs - declared_verbs

    expect(phantom).to be_empty,
                       "the judge offers #{phantom.size} verb(s) the language does not declare; " \
                       "UnknownVerb is swallowed, so these dispatch into silence:\n  #{phantom.join("\n  ")}"
  end

  it "declares every aggregate before it details any of them" do
    # Attributes are offered after every aggregate exists, so `points_at` can resolve
    # a head declared later in the file; banking passes only by declaration order.
    verbs = offered_in_order

    expect(verbs.rindex("Bluebook::Aggregate.Declare"))
      .to be < verbs.index("Bluebook::Aggregate.Attribute")
  end
end
