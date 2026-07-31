
require "spec_helper"

# The language's rules, expressed in the language.
#
# Seventeen rules live as `raise Malformed` across seven builder files. Stage
# one of defining the language in itself is porting them into the meta-domain
# as `given` and `invariant`, where they are declarations rather than code —
# and where a second runtime could read them, which today it cannot (Rust's
# parser has zero error sites and accepts bluebooks Ruby refuses).
#
# Every rule here must be SEEN REFUSING. A ported rule that never fires is the
# same defect the whole corpus keeps producing, and porting rules is exactly
# the activity most likely to produce it.
RSpec.describe "the language's own rules" do

  def boot_meta
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(Hecksagain::Bluebook::MetaValidator::GRAMMAR)
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  def v(text) = { value: text.to_s }

  before do
    @runtime = boot_meta
    # A bluebook is reached by id like every other root. It used to be
    # identified_by :name, which made `Bluebook.Normalise` unable to name what it
    # acts on — the runtime reads an argument called `name` as the reference.
    @runtime.dispatch("Meta::Bluebook.Declare", id: "D", name: v("D"),
                      vision: v("a vision"), classification: v("core"))
    @runtime.dispatch("Meta::Aggregate.Declare", id: "D::A", bluebook_id: v("D"),
                      name: v("A"), description: v("an aggregate"), identified_by: v(""))
  end

  # ---- tier 1 : presence, as invariants on the value ------------------------

  it "refuses a chapter whose vision says nothing" do
    expect { @runtime.dispatch("Meta::Bluebook.Declare", id: "E", name: v("E"), vision: v(""), classification: v("core")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a vision says something/)
  end

  it "refuses an aggregate whose description says nothing" do
    expect { @runtime.dispatch("Meta::Aggregate.Declare", id: "D::B", bluebook_id: v("D"),
                               name: v("B"), description: v(""), identified_by: v("")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a description says something/)
  end

  it "refuses an attribute that is not named" do
    expect { @runtime.dispatch("Meta::Aggregate.Attribute", id: "D::A", name: v(""), type: v("T"), list: v("false")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /an attribute is named/)
  end

  # "attributes must use value-object types" is no longer a predicate — the
  # type IS a reference to the value object, so an undeclared one cannot resolve
  it "refuses an attribute whose type is not a declared value object" do
    expect { @runtime.dispatch("Meta::Aggregate.Attribute", id: "D::A", name: v("x"),
                               type: v("D::A.Nonexistent"), list: v("false")) }
      .to raise_error(Hecksagain::Runtime::NotFound, /no ValueObject with/)
  end

  it "refuses a value object that is not named" do
    expect { @runtime.dispatch("Meta::ValueObject.Declare", id: "D::A.X", aggregate_id: v("D::A"), name: v("")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a value object is named/)
  end

  context "with a command declared" do
    before do
      @runtime.dispatch("Meta::Command.Declare", id: "D::A.C", aggregate_id: v("D::A"),
                        name: v("C"), role: v("Someone"), goal: v("do a thing"))
    end

    it "refuses a given with no description" do
      expect { @runtime.dispatch("Meta::Command.Rule", id: "D::A.C", description: v(""), canonical: v("x > 1")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a rule says what it means/)
    end

    it "refuses a rule that did not survive extraction" do
      expect { @runtime.dispatch("Meta::Command.Rule", id: "D::A.C", description: v("a rule"), canonical: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a rule survives extraction/)
    end

    it "refuses a mutation with no target" do
      expect { @runtime.dispatch("Meta::Command.Change", id: "D::A.C", target: v(""), op: v("set"),
                                 field: v(""), kind: v("literal"), source: v('"x"')) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a mutation names a target/)
    end

    it "refuses a mutation whose op the runtime does not apply" do
      expect { @runtime.dispatch("Meta::Command.Change", id: "D::A.C", target: v("x"), op: v("frobnicate"),
                                 field: v(""), kind: v("literal"), source: v('"x"')) }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /an op is one the runtime applies/)
    end

    it "refuses an unnamed event" do
      expect { @runtime.dispatch("Meta::Command.Announce", id: "D::A.C", announces: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /an event is named/)
    end

    # ---- tier 2 : once-only, read from the instance's own state -------------

    it "refuses a command that acts on a SECOND root" do
      @runtime.dispatch("Meta::Command.ActsOn", id: "D::A.C", root: v("A"))

      expect { @runtime.dispatch("Meta::Command.ActsOn", id: "D::A.C", root: v("B")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a command acts on ONE root/)
    end

    it "refuses a reference that names nothing" do
      expect { @runtime.dispatch("Meta::Command.ActsOn", id: "D::A.C", root: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a command names what it acts on/)
    end
  end

  it "refuses a read model gathering heads before its reference" do
    @runtime.dispatch("Meta::ReadModel.Declare", id: "D.P", bluebook_id: v("D"), name: v("P"),
                      description: v("a projection"), query_name: v("p"),
                      reference_name: v(""), reference_target: v(""))

    expect { @runtime.dispatch("Meta::ReadModel.Gather", id: "D.P", aggregate: v("A"), as: v("a"), many: v("false")) }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /gathers heads only after its reference/)
  end

  # A PIECE MUST SAY WHAT IT IS KNOWN BY. Not invented for the rule's own sake:
  # `bin/undeclared` perturbs banking's Withdrawal by dropping this very line and
  # reported it MASKING A DIVERGENCE — without it Ruby refused with "pass :" and
  # Rust with "pass id:", so the declaration was the only reason the two runtimes
  # agreed. The rule removes the default there was to disagree about.
  it "refuses an entity that does not say what it is known by" do
    expect do
      @runtime.dispatch("Meta::Entity.Declare", id: "D::A.E", aggregate_id: v("D::A"), owner: v("A"),
                        name: v("E"), description: v("a piece"), identified_by: v(""), position: { value: 0 })
    end.to raise_error(Hecksagain::Runtime::GivenNotMet, /an entity says what it is known by/)
  end

  # AN IDENTITY NAMES A FIELD, so the runtime never has to open a value object
  # and guess which one was meant. The unwrap that used to do the guessing is
  # gone from Value, so a declaration that stops at the attribute would leave the
  # whole object standing as the id.
  it "refuses an entity known by a whole value object rather than a field" do
    expect do
      @runtime.dispatch("Meta::Entity.Declare", id: "D::A.E", aggregate_id: v("D::A"), owner: v("A"),
                        name: v("E"), description: v("a piece"), identified_by: v("sequence"),
                        position: { value: 0 })
    end.to raise_error(Hecksagain::Runtime::GivenNotMet, /an entity is known by a field/)
  end

  it "refuses an aggregate known by a whole value object rather than a field" do
    @runtime.dispatch("Meta::Aggregate.Declare", id: "D::C", bluebook_id: v("D"),
                      name: v("C"), description: v("an aggregate"), identified_by: v("number"))

    expect { @runtime.dispatch("Meta::Aggregate.Seal", id: "D::C") }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /an aggregate that is identified names a field/)
  end

  it "admits an aggregate known by the field inside its value object" do
    @runtime.dispatch("Meta::Aggregate.Declare", id: "D::E", bluebook_id: v("D"),
                      name: v("E"), description: v("an aggregate"), identified_by: v("number.value"))

    expect { @runtime.dispatch("Meta::Aggregate.Seal", id: "D::E") }.not_to raise_error
  end

  it "admits an entity that names the field it is known by" do
    expect do
      @runtime.dispatch("Meta::Entity.Declare", id: "D::A.E", aggregate_id: v("D::A"), owner: v("A"),
                        name: v("E"), description: v("a piece"), identified_by: v("sequence.value"),
                        position: { value: 0 })
    end.not_to raise_error
  end

  it "refuses an admitted row that binds no named field" do
    @runtime.dispatch("Meta::ValueObject.Declare", id: "D::A.X", aggregate_id: v("D::A"), name: v("X"))
    @runtime.dispatch("Meta::Member.Declare", id: "D::A.X#0", value_object_id: v("D::A.X"), shape: v("D::A.X"))

    expect { @runtime.dispatch("Meta::Member.Pair", id: "D::A.X#0", key: v(""), value: v("q")) }
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
    @runtime.dispatch("Meta::ValueObject.Declare", id: "D::A.X", aggregate_id: v("D::A"), name: v("X"))
    @runtime.dispatch("Meta::Aggregate.Attribute", id: "D::A", name: v("x"), type: v("D::A.X"), list: v("false"))

    expect { @runtime.dispatch("Meta::Aggregate.Seal", id: "D::A") }.not_to raise_error
  end
end
