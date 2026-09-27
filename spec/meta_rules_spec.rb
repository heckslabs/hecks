require "spec_helper"

# The language's own rules, expressed in the language as `given` and `invariant`.
# Every rule here must be seen refusing.
RSpec.describe "the language's own rules" do
  def boot_meta
    registry = Hecks::Runtime::Registry.new
    Hecks::Bluebook::MetaValidator.load_grammar_into(registry)
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def v(text) = { value: text.to_s }

  # The id of what was just declared; ids derive from declared facts, so read it off the result.
  def id_of(verb, **args) = @runtime.dispatch_flat(verb, **args).instance.id

  before do
    @runtime = boot_meta
    # A bluebook is reached by its own name (identified_by { name.value }); a minted id would
    # collide with the `name` argument's reference lookup.
    @bluebook_id = id_of("Bluebook::Bluebook.Declare", name: v("D"),
                         vision: v("a vision"), classification: v("core"))
    @aggregate_id = id_of("Bluebook::Aggregate.Declare", bluebook: @bluebook_id,
                          name: v("A"), description: v("an aggregate"))
    # Fully declared, so later dispatches exercise one well-formed aggregate.
    @runtime.dispatch("Bluebook::Aggregate.Identify", to: @aggregate_id, with: { path: v("name.value") })
  end

  it "refuses a chapter whose vision says nothing" do
    expect { @runtime.dispatch_flat("Bluebook::Bluebook.Declare", name: v("E"), vision: v(""), classification: v("core")) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a vision says something/)
  end

  it "refuses an aggregate whose description says nothing" do
    expect do
      @runtime.dispatch_flat("Bluebook::Aggregate.Declare", bluebook: @bluebook_id,
                               name: v("B"), description: v(""))
    end
      .to raise_error(Hecks::Runtime::InvariantViolation, /a description says something/)
  end

  it "refuses an attribute that is not named" do
    expect { @runtime.dispatch("Bluebook::Aggregate.Attribute", to: @aggregate_id, with: { name: v(""), type: "T", list: v("false") }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /an attribute is named/)
  end

  # The type is a reference to the value object, so an undeclared one cannot resolve.
  it "refuses an attribute whose type is not a declared value object" do
    expect do
      @runtime.dispatch("Bluebook::Aggregate.Attribute", to:   @aggregate_id,
                                                         with: { name: v("x"),
                                                                 type: "#{@aggregate_id}.Nonexistent",
                                                                 list: v("false") })
    end
      .to raise_error(Hecks::Runtime::NotFound, /no ValueObject with/)
  end

  it "refuses a value object that is not named" do
    # ValueObjectName's `pattern:` is coerced before invariants run, so an empty name is a
    # TypeMismatch; the invariant only guards whitespace-only names.
    expect { @runtime.dispatch_flat("Bluebook::ValueObject.Declare", aggregate: @aggregate_id, name: v("")) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /ValueObjectName\.value must match/)
  end

  context "with a command declared" do
    before do
      # Owned directly by the aggregate, so owner_id is the aggregate's own id.
      @command_id = id_of("Bluebook::Command.Declare", owner_id: @aggregate_id, aggregate: @aggregate_id,
                          name: v("C"), role: v("Someone"), goal: v("do a thing"))
    end

    it "refuses a given with no description" do
      expect { @runtime.dispatch("Bluebook::Command.Rule", to: @command_id, with: { description: v(""), canonical: v("x > 1") }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /a rule says what it means/)
    end

    it "refuses a rule that did not survive extraction" do
      expect { @runtime.dispatch("Bluebook::Command.Rule", to: @command_id, with: { description: v("a rule"), canonical: v("") }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /a rule survives extraction/)
    end

    it "refuses a mutation with no target" do
      expect do
        @runtime.dispatch("Bluebook::Command.Change", to:   @command_id,
                                                      with: { target: v(""),
                                                              op:     v("set"),
                                                              field:  v(""),
                                                              kind:   v("literal"),
                                                              source: v('"x"') })
      end
        .to raise_error(Hecks::Runtime::GivenNotMet, /a mutation names a target/)
    end

    # `op` admits Vocabulary::MutationOp rather than restating the set in an invariant, so the
    # refusal names the set and there is no second copy to drift.
    it "refuses a mutation whose op the runtime does not apply" do
      expect do
        @runtime.dispatch("Bluebook::Command.Change", to:   @command_id,
                                                      with: { target: v("x"),
                                                              op:     v("frobnicate"),
                                                              field:  v(""),
                                                              kind:   v("literal"),
                                                              source: v('"x"') })
      end
        .to raise_error(Hecks::Runtime::InvariantViolation, /op admits Vocabulary::MutationOp/)
    end

    it "refuses an unnamed event" do
      expect { @runtime.dispatch("Bluebook::Command.Announce", to: @command_id, with: { announces: v("") }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /an event is named/)
    end

    it "refuses a command that acts on a SECOND root" do
      @runtime.dispatch("Bluebook::Command.ActsOn", to: @command_id, with: { root: v("A") })

      expect { @runtime.dispatch("Bluebook::Command.ActsOn", to: @command_id, with: { root: v("B") }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /a command acts on ONE root/)
    end

    it "refuses a reference that names nothing" do
      expect { @runtime.dispatch("Bluebook::Command.ActsOn", to: @command_id, with: { root: v("") }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /a command names what it acts on/)
    end
  end

  # reference_to is optional, so a rootless read model with no reference_target may gather heads.
  it "allows a rootless read model (no reference_target at all) to gather heads" do
    read_model_id = id_of("Bluebook::ReadModel.Declare", bluebook: @bluebook_id, name: v("P"),
                          description: v("a projection"), query_name: v("p"),
                          reference_name: v(""), reference_target: v(""))

    expect { @runtime.dispatch("Bluebook::ReadModel.Gather", to: read_model_id, with: { aggregate: v("A"), as: v("a"), many: v("false") }) }
      .not_to raise_error
  end

  # A piece must say what it is known by: Declare leaves the identity list empty and Seal notices.
  it "refuses an entity that does not say what it is known by" do
    entity_id = id_of("Bluebook::Entity.Declare", aggregate: @aggregate_id, owner: v("A"),
                      name: v("E"), description: v("a piece"), position: { value: 0 })

    expect { @runtime.dispatch("Bluebook::Entity.Seal", to: entity_id) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /an entity says what it is known by/)
  end

  # Whether a part is a dotted unwrap, a reference or a bare scalar is the builder's question
  # (ADR 0025); this rule only checks that each appended part is named.
  it "admits a bare scalar identity part — the builder resolves its shape, not this rule" do
    entity_id = id_of("Bluebook::Entity.Declare", aggregate: @aggregate_id, owner: v("A"),
                      name: v("E"), description: v("a piece"), position: { value: 0 })

    expect { @runtime.dispatch("Bluebook::Entity.Identify", to: entity_id, with: { path: v("sequence") }) }
      .not_to raise_error
  end

  it "admits a dotted identity part naming the field inside a value object" do
    entity_id = id_of("Bluebook::Entity.Declare", aggregate: @aggregate_id, owner: v("A"),
                      name: v("E"), description: v("a piece"), position: { value: 0 })

    expect { @runtime.dispatch("Bluebook::Entity.Identify", to: entity_id, with: { path: v("sequence.value") }) }
      .not_to raise_error
  end

  it "refuses an entity identity part with no name at all" do
    entity_id = id_of("Bluebook::Entity.Declare", aggregate: @aggregate_id, owner: v("A"),
                      name: v("E"), description: v("a piece"), position: { value: 0 })

    expect { @runtime.dispatch("Bluebook::Entity.Identify", to: entity_id, with: { path: v("") }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /an identity part names something/)
  end

  # The per-part rule fires on Identify; "known by at all" is Seal's, run once every part arrived.
  it "admits a bare scalar aggregate identity part" do
    aggregate_id = id_of("Bluebook::Aggregate.Declare", bluebook: @bluebook_id,
                         name: v("C"), description: v("an aggregate"))

    expect { @runtime.dispatch("Bluebook::Aggregate.Identify", to: aggregate_id, with: { path: v("number") }) }
      .not_to raise_error
  end

  it "admits an aggregate known by the field inside its value object" do
    aggregate_id = id_of("Bluebook::Aggregate.Declare", bluebook: @bluebook_id,
                         name: v("E"), description: v("an aggregate"))

    expect { @runtime.dispatch("Bluebook::Aggregate.Identify", to: aggregate_id, with: { path: v("number.value") }) }
      .not_to raise_error
  end

  it "refuses an aggregate identity part with no name at all" do
    aggregate_id = id_of("Bluebook::Aggregate.Declare", bluebook: @bluebook_id,
                         name: v("F"), description: v("an aggregate"))

    expect { @runtime.dispatch("Bluebook::Aggregate.Identify", to: aggregate_id, with: { path: v("") }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /an identity part names something/)
  end

  # A command's reference_to is offered as the head's own id, so no predicate checks it exists.
  it "refuses an argument that references a head nobody declared" do
    command_id = id_of("Bluebook::Command.Declare", owner_id: @aggregate_id, aggregate: @aggregate_id,
                       name: v("C"), role: v("Clerk"), goal: v("do a thing"))

    expect do
      @runtime.dispatch("Bluebook::Command.Reference", to:   command_id,
                                                       with: { points_at: "#{@bluebook_id}::Nonexistent",
                                name: v("customer_id"), list: v("false"), default: v("") })
    end.to raise_error(Hecks::Runtime::NotFound, /no Aggregate with/)
  end

  # ValueObject.Member appends the row; the dotted ValueObject.Member.Pair fills it in (ADR 0026).
  it "refuses an admitted row that binds no named field" do
    name = v("X")
    value_object_id = id_of("Bluebook::ValueObject.Declare", aggregate: @aggregate_id, name: name)
    @runtime.dispatch("Bluebook::ValueObject.Member", to: value_object_id, with: { position: { value: 0 } })

    expect do
      @runtime.dispatch_flat("Bluebook::ValueObject.Member.Pair", aggregate: @aggregate_id, name: name,
                        position: { value: 0 }, key: v(""), value: v("q"))
    end.to raise_error(Hecks::Runtime::GivenNotMet, /an admitted row binds a named field/)
  end

  # Seal has no "at least one attribute" rule: a lifecycle-only aggregate declares none.
  it "seals an aggregate that is fully declared" do
    value_object_id = id_of("Bluebook::ValueObject.Declare", aggregate: @aggregate_id, name: v("X"))
    @runtime.dispatch("Bluebook::Aggregate.Attribute", to:   @aggregate_id,
                                                       with: { name: v("x"), type: value_object_id, list: v("false") })

    expect { @runtime.dispatch("Bluebook::Aggregate.Seal", to: @aggregate_id) }.not_to raise_error
  end
end
