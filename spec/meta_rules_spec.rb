
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
    @runtime.dispatch("Meta::Chapter.Declare", name: v("D"), vision: v("a vision"), classification: v("core"))
    @runtime.dispatch("Meta::Root.Declare", id: "D::A", chapter_id: v("D"),
                      name: v("A"), description: v("an aggregate"), identity: v(""))
  end

  # ---- tier 1 : presence, as invariants on the value ------------------------

  it "refuses a chapter whose vision says nothing" do
    expect { @runtime.dispatch("Meta::Chapter.Declare", name: v("E"), vision: v(""), classification: v("core")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a vision says something/)
  end

  it "refuses an aggregate whose description says nothing" do
    expect { @runtime.dispatch("Meta::Root.Declare", id: "D::B", chapter_id: v("D"),
                               name: v("B"), description: v(""), identity: v("")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a description says something/)
  end

  it "refuses an attribute that is not named" do
    expect { @runtime.dispatch("Meta::Root.Attribute", id: "D::A", name: v(""), type: v("T"), list: v("false")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /an attribute is named/)
  end

  # "attributes must use value-object types" is no longer a predicate — the
  # type IS a reference to the value object, so an undeclared one cannot resolve
  it "refuses an attribute whose type is not a declared value object" do
    expect { @runtime.dispatch("Meta::Root.Attribute", id: "D::A", name: v("x"),
                               type: v("D::A.Nonexistent"), list: v("false")) }
      .to raise_error(Hecksagain::Runtime::NotFound, /no Shape with/)
  end

  it "refuses a value object that is not named" do
    expect { @runtime.dispatch("Meta::Shape.Declare", id: "D::A.X", root_id: v("D::A"), name: v("")) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a value object is named/)
  end

  context "with a command declared" do
    before do
      @runtime.dispatch("Meta::Verb.Declare", id: "D::A.C", root_id: v("D::A"),
                        name: v("C"), role: v("Someone"), goal: v("do a thing"))
    end

    it "refuses a given with no description" do
      expect { @runtime.dispatch("Meta::Verb.Rule", id: "D::A.C", description: v(""), canonical: v("x > 1")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a rule says what it means/)
    end

    it "refuses a rule that did not survive extraction" do
      expect { @runtime.dispatch("Meta::Verb.Rule", id: "D::A.C", description: v("a rule"), canonical: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a rule survives extraction/)
    end

    it "refuses a mutation with no target" do
      expect { @runtime.dispatch("Meta::Verb.Change", id: "D::A.C", target: v(""), op: v("set"),
                                 field: v(""), kind: v("literal"), source: v('"x"')) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a mutation names a target/)
    end

    it "refuses a mutation whose op the runtime does not apply" do
      expect { @runtime.dispatch("Meta::Verb.Change", id: "D::A.C", target: v("x"), op: v("frobnicate"),
                                 field: v(""), kind: v("literal"), source: v('"x"')) }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /an op is one the runtime applies/)
    end

    it "refuses an unnamed event" do
      expect { @runtime.dispatch("Meta::Verb.Announce", id: "D::A.C", announces: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /an event is named/)
    end

    # ---- tier 2 : once-only, read from the instance's own state -------------

    it "refuses a command that acts on a SECOND root" do
      @runtime.dispatch("Meta::Verb.ActsOn", id: "D::A.C", root: v("A"))

      expect { @runtime.dispatch("Meta::Verb.ActsOn", id: "D::A.C", root: v("B")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a command acts on ONE root/)
    end

    it "refuses a reference that names nothing" do
      expect { @runtime.dispatch("Meta::Verb.ActsOn", id: "D::A.C", root: v("")) }
        .to raise_error(Hecksagain::Runtime::GivenNotMet, /a command names what it acts on/)
    end
  end

  it "refuses a read model gathering heads before its reference" do
    @runtime.dispatch("Meta::Projection.Declare", id: "D.P", chapter_id: v("D"), name: v("P"),
                      purpose: v("a projection"), query_name: v("p"), ref_name: v(""), ref_target: v(""))

    expect { @runtime.dispatch("Meta::Projection.Gather", id: "D.P", aggregate: v("A"), as: v("a"), many: v("false")) }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /gathers heads only after its reference/)
  end

  it "refuses an admitted row that binds no named field" do
    @runtime.dispatch("Meta::Shape.Declare", id: "D::A.X", root_id: v("D::A"), name: v("X"))
    @runtime.dispatch("Meta::Member.Declare", id: "D::A.X#0", shape_id: v("D::A.X"), shape: v("D::A.X"))

    expect { @runtime.dispatch("Meta::Member.Pair", id: "D::A.X#0", key: v(""), value: v("q")) }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /an admitted row binds a named field/)
  end

  # ---- tier 3 : whole-document, dispatched once everything is declared ------

  it "refuses to seal an aggregate that declares no attribute" do
    expect { @runtime.dispatch("Meta::Root.Seal", id: "D::A") }
      .to raise_error(Hecksagain::Runtime::GivenNotMet, /declares at least one attribute/)
  end

  it "seals an aggregate that is fully declared" do
    @runtime.dispatch("Meta::Shape.Declare", id: "D::A.X", root_id: v("D::A"), name: v("X"))
    @runtime.dispatch("Meta::Root.Attribute", id: "D::A", name: v("x"), type: v("D::A.X"), list: v("false"))

    expect { @runtime.dispatch("Meta::Root.Seal", id: "D::A") }.not_to raise_error
  end
end
