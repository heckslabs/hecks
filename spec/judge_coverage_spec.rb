
require "spec_helper"

# Every VERB the language declares must be OFFERED to it.
#
# A rule the judge never dispatches input to cannot fire. That has now happened
# three times in this validator. Five rules were declared and unreachable after
# the first pass. Policies, process managers and entities went unjudged after
# the second — banking's three policies and its Settlement saga passed through
# validation untouched, so any rule about them was decoration. This spec was
# written to catch the third, and did not, because it guarded only `*.Declare`:
# thirteen verbs — among them `Command.Argument` and `ValueObject.Field`, so a
# command's own arguments and a value object's own fields were NEVER judged —
# sat declared and unreachable underneath a green guard.
#
# So the map is gone. Nothing here is hand-kept any more: the expectation is
# DERIVED from the language, and a verb the language declares is a verb the
# judge owes an offer. Adding a command to bluebook.bluebook without teaching
# the judge to offer it is exactly the failure this catches, and now it catches
# it at the grain of the verb rather than the grain of the category.
#
# `experiment/replay.rb` used to catch this indirectly: it rebuilt the IR from
# the meta-domain and diffed, so a dropped category stopped matching. That is a
# lot of machinery to answer a question this asks directly, and the reconstruction
# half was never needed for validation. This replaces it.
RSpec.describe "the judge's coverage of the language" do
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
    judge.instance_variable_set(
      :@plan,
      Hecksagain::Bluebook::MetaValidator::Plan.for(Hecksagain::Bluebook::MetaValidator.grammar_registry)
    )
    judge.send(:judge!)
    spy.verbs.uniq
  end

  # Every command on every aggregate of the meta-domain, spelled as the judge
  # would dispatch it. World and Wiring live in world.bluebook and are judged
  # through their own door (MetaValidator.call_world), so `bluebook("Meta")`
  # leaves them out by construction rather than by exclusion list. Vocabulary
  # declares no commands, so it contributes nothing and needs no special case —
  # it is static declaration read from the IR by spec/vocabulary_conformance_spec.
  def declared_verbs
    Hecksagain::Bluebook::MetaValidator.grammar_registry
      .bluebook("Meta").aggregates
      .flat_map { |aggregate| aggregate.commands.map { |c| "Meta::#{aggregate.name}.#{c.name}" } }
  end

  it "offers every verb the language declares" do
    missing = declared_verbs - offered_verbs

    expect(missing).to be_empty,
                       "the language declares #{missing.size} verb(s) the judge never offers, " \
                       "so every rule hanging off them is decoration:\n  #{missing.join("\n  ")}"
  end

  it "offers no verb the language does not declare" do
    # The judge swallows Runtime::UnknownVerb, so a misspelled or retired verb
    # is dispatched into silence and every rule it was carrying stops firing
    # with nothing going red. This is the other half of the same failure.
    phantom = offered_verbs - declared_verbs

    expect(phantom).to be_empty,
                       "the judge offers #{phantom.size} verb(s) the language does not declare; " \
                       "UnknownVerb is swallowed, so these dispatch into silence:\n  #{phantom.join("\n  ")}"
  end
end
