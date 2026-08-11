
require "spec_helper"

# The language's rules, expressed in the language.
#
# Seventeen rules live as `raise Malformed` across seven builder files. Stage
# one of defining the language in itself is porting them into the meta-domain
# as `given` and `invariant`, where they are declarations rather than code —
# facts any reader of the meta-domain can consume, instead of behavior buried
# in the builders.
#
# Every rule here must be SEEN REFUSING. A ported rule that never fires is the
# same defect the whole corpus keeps producing, and porting rules is exactly
# the activity most likely to produce it.
RSpec.describe "the language's own rules" do

  def boot_meta
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain::Bluebook::MetaValidator.load_grammar_into(registry)
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  def v(text) = { value: text.to_s }

  # THE ID OF WHAT WAS JUST DECLARED. Nothing here is minted any more — every
  # meta-record's id is DERIVED from the facts it was declared with, so a test
  # cannot simply invent one. Reading it back off the dispatch result is the
  # only honest way to name a record in a later dispatch : the same derivation
  # the runtime just ran, not a second guess at what it must have computed.
  def id_of(verb, **args) = @runtime.dispatch(verb, **args).instance.id

  before do
    @runtime = boot_meta
    # A bluebook is reached by id like every other root. It used to be reached
    # by a MINTED id, which made `Bluebook.Normalise` unable to name what it
    # acts on — the runtime read an argument called `name` as the reference
    # lookup. It is reached by its own name now (Bluebook.identified_by {
    # name.value }), so the lookup collision is gone rather than ducked.
    @bluebook_id = id_of("Bluebook::Bluebook.Declare", name: v("D"),
                         vision: v("a vision"), classification: v("core"))
    @aggregate_id = id_of("Bluebook::Aggregate.Declare", bluebook_id: @bluebook_id,
                          name: v("A"), description: v("an aggregate"))
    # Fully declared, so tests that dispatch further commands against it (an
    # attribute, a command, a seal) are exercising ONE well-formed aggregate,
    # not the identity rule a few tests down deliberately withhold.
    @runtime.dispatch("Bluebook::Aggregate.Identify", id: @aggregate_id, path: v("name.value"))
  end

  # ---- tier 1 : presence, as invariants on the value ------------------------

  it "refuses a chapter whose vision says nothing" do
    expect { @runtime.dispatch("Bluebook::Bluebook.Declare", name: v("E"), vision: v(""), classification: v("core")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a vision says something/)
  end

  it "refuses an aggregate whose description says nothing" do
    expect { @runtime.dispatch("Bluebook::Aggregate.Declare", bluebook_id: @bluebook_id,
                               name: v("B"), description: v("")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a description says something/)
  end

  it "refuses an attribute that is not named" do
    expect { @runtime.dispatch("Bluebook::Aggregate.Attribute", id: @aggregate_id, name: v(""), type: "T", list: v("false")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /an attribute is named/)
  end

  # "attributes must use value-object types" is no longer a predicate — the
  # type IS a reference to the value object, so an undeclared one cannot resolve
  it "refuses an attribute whose type is not a declared value object" do
    expect { @runtime.dispatch("Bluebook::Aggregate.Attribute", id: @aggregate_id, name: v("x"),
                               type: "#{@aggregate_id}.Nonexistent", list: v("false")) }
      .to raise_error(Hecksagain::Runtime::NotFound, /no ValueObject with/)
  end

  it "refuses a value object that is not named" do
    expect { @runtime.dispatch("Bluebook::ValueObject.Declare", aggregate_id: @aggregate_id, name: v("")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a value object is named/)
  end

  context "with a command declared" do
    before do
      # OWNED DIRECTLY BY THE AGGREGATE, so owner_id (what the identity is
      # built from) is the aggregate's own id — the same fact `aggregate_id`
      # carries here, since nothing about this command comes from an entity.
      @command_id = id_of("Bluebook::Command.Declare", owner_id: @aggregate_id, aggregate_id: @aggregate_id,
                          name: v("C"), role: v("Someone"), goal: v("do a thing"))
    end

    it "refuses a given with no description" do
      expect { @runtime.dispatch("Bluebook::Command.Rule", id: @command_id, description: v(""), canonical: v("x > 1")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a rule says what it means/)
    end

    it "refuses a rule that did not survive extraction" do
      expect { @runtime.dispatch("Bluebook::Command.Rule", id: @command_id, description: v("a rule"), canonical: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a rule survives extraction/)
    end

    it "refuses a mutation with no target" do
      expect { @runtime.dispatch("Bluebook::Command.Change", id: @command_id, target: v(""), op: v("set"),
                                 field: v(""), kind: v("literal"), source: v('"x"')) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a mutation names a target/)
    end

    # THE SAME REFUSAL, FROM A NAMED SET RATHER THAN A RESTATED ONE.
    #
    # `Command::OpName` used to carry `set || append || increment || decrement`
    # in an invariant — Vocabulary::MutationOp written out a second time, one
    # level in, where nothing compared the two. `Change.op` now says
    # `admits: "Vocabulary::MutationOp"` and coercion refuses a non-member, so
    # the rule still fires at the door and there is no second copy to drift.
    #
    # The message names the SET, which the invariant never could: the old one
    # could only say "an op is one the runtime applies" and leave the reader to
    # find out which.
    it "refuses a mutation whose op the runtime does not apply" do
      expect { @runtime.dispatch("Bluebook::Command.Change", id: @command_id, target: v("x"), op: v("frobnicate"),
                                 field: v(""), kind: v("literal"), source: v('"x"')) }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /op admits Vocabulary::MutationOp/)
    end

    it "refuses an unnamed event" do
      expect { @runtime.dispatch("Bluebook::Command.Announce", id: @command_id, announces: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /an event is named/)
    end

    # ---- tier 2 : once-only, read from the instance's own state -------------

    it "refuses a command that acts on a SECOND root" do
      @runtime.dispatch("Bluebook::Command.ActsOn", id: @command_id, root: v("A"))

      expect { @runtime.dispatch("Bluebook::Command.ActsOn", id: @command_id, root: v("B")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a command acts on ONE root/)
    end

    it "refuses a reference that names nothing" do
      expect { @runtime.dispatch("Bluebook::Command.ActsOn", id: @command_id, root: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a command names what it acts on/)
    end
  end

  # WAS "refuses a read model gathering heads before its reference" —
  # reference_target is fixed forever at Declare time, so that rule was
  # really "every read model must have SOME reference, ever," which
  # stopped being true the moment `reference_to` became optional (a
  # ROOTLESS read model — bulk, no root, `group_by`'s own real use —
  # never has one, permanently, on purpose). Gathering with an empty
  # reference_target is now the legitimate rootless case, not a defect.
  it "allows a rootless read model (no reference_target at all) to gather heads" do
    read_model_id = id_of("Bluebook::ReadModel.Declare", bluebook_id: @bluebook_id, name: v("P"),
                          description: v("a projection"), query_name: v("p"),
                          reference_name: v(""), reference_target: v(""))

    expect { @runtime.dispatch("Bluebook::ReadModel.Gather", id: read_model_id, aggregate: v("A"), as: v("a"), many: v("false")) }
      .not_to raise_error
  end

  # A PIECE MUST SAY WHAT IT IS KNOWN BY. Not invented for the rule's own sake:
  # perturbing banking's Withdrawal by dropping this very line once exposed
  # that the refusal's wording depended on a fallback default ("pass :" versus
  # "pass id:") — the declaration was the only thing pinning the answer.
  # The rule removes the default there was to disagree about.
  #
  # An entity's identity is no longer an ARGUMENT of Declare — it is appended
  # one part at a time by `Entity.Identify`, exactly as an aggregate's is, so
  # "says what it is known by" is Seal's rule now : Declare alone leaves the
  # list empty, and Seal is what notices.
  it "refuses an entity that does not say what it is known by" do
    entity_id = id_of("Bluebook::Entity.Declare", aggregate_id: @aggregate_id, owner: v("A"),
                      name: v("E"), description: v("a piece"), position: { value: 0 })

    expect { @runtime.dispatch("Bluebook::Entity.Seal", id: entity_id) }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /an entity says what it is known by/)
  end

  # AN IDENTITY NAMES A FIELD, so the runtime never has to open a value object
  # and guess which one was meant. The unwrap that used to do the guessing is
  # gone from Value, so a declaration that stops at the attribute would leave the
  # whole object standing as the id. The rule now fires on EACH PART as it is
  # appended (`Entity.Identify`), not once at Declare.
  it "refuses an entity known by a whole value object rather than a field" do
    entity_id = id_of("Bluebook::Entity.Declare", aggregate_id: @aggregate_id, owner: v("A"),
                      name: v("E"), description: v("a piece"), position: { value: 0 })

    expect { @runtime.dispatch("Bluebook::Entity.Identify", id: entity_id, path: v("sequence")) }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /an identity part reaches a scalar/)
  end

  it "admits an entity that names the field it is known by" do
    entity_id = id_of("Bluebook::Entity.Declare", aggregate_id: @aggregate_id, owner: v("A"),
                      name: v("E"), description: v("a piece"), position: { value: 0 })

    expect { @runtime.dispatch("Bluebook::Entity.Identify", id: entity_id, path: v("sequence.value")) }
      .not_to raise_error
  end

  # Same split as Entity's, above : the per-part scalar rule fires on Identify,
  # and "says what it is known by AT ALL" is Seal's, since Seal is the only
  # command dispatched once every part has had its chance to arrive.
  it "refuses an aggregate known by a whole value object rather than a field" do
    aggregate_id = id_of("Bluebook::Aggregate.Declare", bluebook_id: @bluebook_id,
                         name: v("C"), description: v("an aggregate"))

    expect { @runtime.dispatch("Bluebook::Aggregate.Identify", id: aggregate_id, path: v("number")) }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /an identity part reaches a scalar/)
  end

  it "admits an aggregate known by the field inside its value object" do
    aggregate_id = id_of("Bluebook::Aggregate.Declare", bluebook_id: @bluebook_id,
                         name: v("E"), description: v("an aggregate"))

    expect { @runtime.dispatch("Bluebook::Aggregate.Identify", id: aggregate_id, path: v("number.value")) }
      .not_to raise_error
  end

  # `reference_to` written on a COMMAND, which the language records the same way
  # it records one written on a head: the argument's type is offered as the head's
  # own id, so "points at a declared head" costs no predicate. Before this the
  # judge held a command's reference as the STRING "Reference<Customer>" and a
  # `raise Malformed` beside the builder was the only thing checking it.
  it "refuses an argument that references a head nobody declared" do
    command_id = id_of("Bluebook::Command.Declare", owner_id: @aggregate_id, aggregate_id: @aggregate_id,
                       name: v("C"), role: v("Clerk"), goal: v("do a thing"))

    expect do
      @runtime.dispatch("Bluebook::Command.Reference", id: command_id, points_at: "#{@bluebook_id}::Nonexistent",
                        name: v("customer_id"), list: v("false"), default: v(""))
    end.to raise_error(Hecksagain::Runtime::NotFound, /no Aggregate with/)
  end

  it "refuses an admitted row that binds no named field" do
    value_object_id = id_of("Bluebook::ValueObject.Declare", aggregate_id: @aggregate_id, name: v("X"))
    member_id = id_of("Bluebook::Member.Declare", value_object_id: value_object_id, shape: v("X"), position: { value: 0 })

    expect { @runtime.dispatch("Bluebook::Member.Pair", id: member_id, key: v(""), value: v("q")) }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /an admitted row binds a named field/)
  end

  # ---- tier 3 : whole-document, dispatched once everything is declared ------

  # There is no "an aggregate declares at least one attribute" test any more, and
  # the rule it pinned is gone. It was invented for Seal rather than ported from a
  # builder, so no bluebook was written against it — and the first time Seal was
  # actually dispatched it refused twenty-five of them, including every aggregate
  # whose state is a `lifecycle` rather than an `attribute`. A spec that only ever
  # saw the rule refuse the case it was written beside is not evidence the rule is
  # true.
  it "seals an aggregate that is fully declared" do
    value_object_id = id_of("Bluebook::ValueObject.Declare", aggregate_id: @aggregate_id, name: v("X"))
    @runtime.dispatch("Bluebook::Aggregate.Attribute", id: @aggregate_id, name: v("x"), type: value_object_id, list: v("false"))

    expect { @runtime.dispatch("Bluebook::Aggregate.Seal", id: @aggregate_id) }.not_to raise_error
  end
end
