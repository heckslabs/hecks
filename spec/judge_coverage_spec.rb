
require "spec_helper"

# Every category a bluebook carries must be OFFERED to the language.
#
# A rule the judge never dispatches input to cannot fire. That has now happened
# twice in this validator alone: five rules were declared and unreachable after
# the first pass, and policies, process managers and entities went unjudged
# after the second — banking's three policies and its Settlement saga passed
# through validation untouched, so any rule about them was decoration.
#
# `experiment/replay.rb` used to catch this indirectly: it rebuilt the IR from
# the meta-domain and diffed, so a dropped category stopped matching. That is a
# lot of machinery to answer a question this asks directly, and the reconstruction
# half was never needed for validation. This replaces it.
RSpec.describe "the judge's coverage of a bluebook" do
  # what the language models -> what the judge must dispatch when a bluebook
  # carries one. Adding an aggregate to bluebook.bluebook without teaching the
  # judge to offer it is exactly the failure this catches.
  CATEGORY_VERBS = {
    "Chapter"    => "Meta::Chapter.Declare",
    "Root"       => "Meta::Root.Declare",
    "Shape"      => "Meta::Shape.Declare",
    "Verb"       => "Meta::Verb.Declare",
    "Ask"        => "Meta::Ask.Declare",
    "Piece"      => "Meta::Piece.Declare",
    "Member"     => "Meta::Member.Declare",
    "Reaction"   => "Meta::Reaction.Declare",
    "Saga"       => "Meta::Saga.Declare",
    "Projection" => "Meta::Projection.Declare"
  }.freeze

  # Banking is the only corpus member carrying every category at once.
  def banking
    @banking ||= begin
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
      end
      registry.bluebook("Banking")
    end
  end

  # Records what the judge asks for, without judging anything.
  class Spy
    attr_reader :verbs

    def initialize = @verbs = []
    def dispatch(verb, **_args) = @verbs << verb
    def registry = nil
  end

  def offered_verbs
    spy = Spy.new
    judge = Hecksagain::Bluebook::MetaValidator::Judge.allocate
    judge.instance_variable_set(:@bluebook, banking)
    judge.instance_variable_set(:@refusals, [])
    judge.instance_variable_set(:@runtime, spy)
    judge.send(:judge!)
    spy.verbs.uniq
  end

  it "offers every category the language models and banking carries" do
    expect(offered_verbs).to include(*CATEGORY_VERBS.values)
  end

  it "names every aggregate the language declares, so a new one cannot be forgotten" do
    # THIS is the guard. Add an aggregate to bluebook.bluebook — a World, say —
    # and this fails until the judge is taught to offer it. Without it, the
    # language can grow a category that silently judges nothing, which is how
    # policies, sagas and entities went unjudged in the first place.
    #
    # Vocabulary is excluded on purpose : it is static declaration read from the
    # IR by spec/vocabulary_conformance_spec, never dispatched.
    declared = Hecksagain::Bluebook::MetaValidator.grammar_registry
                 .bluebook("Meta").aggregates.map(&:name) - %w[Vocabulary Leg Send]

    expect(CATEGORY_VERBS.keys).to match_array(declared)
  end
end
