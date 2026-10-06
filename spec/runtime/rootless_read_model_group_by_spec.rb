require "spec_helper"
require "tmpdir"
require_relative "../support/read_model_spec_helpers"

# A rootless read model (no `reference_to`) nests a many-side head's own
# table by field values via `group_by`, unwrapping single-attribute value
# objects to bare scalars along the way. Every report without group_by
# stays unaffected.
RSpec.describe "a rootless read model's own group_by" do
  include ReadModelSpecHelpers

  # "Gadget", not "Widget" — other spec files declare their own
  # top-level "Widget" domain; nesting a same-named constant under
  # "Nested" here caused a real, order-dependent lookup collision
  # under `config.order = :random`.
  NESTED_GROUP_DOMAIN = proc do
    vision "x"
    generic

    aggregate "Gadget" do
      identified_by :ref
      attribute :ref,   Ref
      attribute :group, Ref
      value_object "Ref" do
        attribute :value, String
      end
      command "Declare" do
        attribute :ref,   Ref
        attribute :group, Ref
        sets :ref
        sets :group
      end
    end

    read_model "Grouped" do
      include Gadget

      group_by :group, :ref
    end
  end

  COLLIDING_DOMAIN = proc do
    vision "x"
    generic

    aggregate "Sprocket" do
      identified_by :ref
      attribute :ref,   Ref
      attribute :group, Ref
      value_object "Ref" do
        attribute :value, String
      end
      command "Declare" do
        attribute :ref,   Ref
        attribute :group, Ref
        sets :ref
        sets :group
      end
    end

    read_model "ByGroup" do
      include Sprocket

      group_by :group
    end

    read_model "ByGroupAndRef" do
      include Sprocket

      group_by :group, :ref
    end
  end

  ROOTFUL_GROUP_DOMAIN = proc do
    vision "x"
    generic
    instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)

    read_model "Solo" do
      reference_to Account
      include Account

      group_by :ref
    end
  end

  CROWDED_GROUP_DOMAIN = proc do
    vision "x"
    generic
    instance_exec(&READ_MODEL_ACCOUNT_AGGREGATE)
    instance_exec(&READ_MODEL_ENTRY_AGGREGATE)

    read_model "Both" do
      include Account
      include Entry

      group_by :ref
    end
  end

  # Three gadgets: w1 and w2 share group g1, w3 is alone in g2.
  GADGET_REFS = [["w1", "g1"], ["w2", "g1"], ["w3", "g2"]].freeze

  COLLISION_MESSAGE = 'ByGroup groups by group, but rows "w1", "w2" share group = g1 — a group_by leaf holds one row; ' \
                      "add a field that tells them apart".freeze

  GROUPED_BY_GROUP_AND_REF = { "g1" => { "w1" => { id: "w1" }, "w2" => { id: "w2" } },
                               "g2" => { "w3" => { id: "w3" } } }.freeze

  def build(adapter: "Memory") = boot_banking_bundle(adapter: adapter, names: ["Customer", "Account"])

  def open_accounts(_runtime)
    Banking::Customer.register!(reference: { value: "c1" }, name: { given: "A", family: "B" },
                                email: { address: "a@example.com" })
    [["a1", "current"], ["a2", "savings"], ["a3", "current"]].each do |number, kind|
      Banking::Account.open!(customer: "c1", number: { value: number }, kind: { name: kind }, daily_limit: { cents: 0 })
    end
  end

  def accounts_by_kind(runtime) = runtime.query("Banking.accounts_by_kind").first[:accounts]

  def sqlite_with_accounts(dir)
    runtime = boot_sqlite_banking(dir, persisted: ["Customer", "Account"])
    open_accounts(runtime)
    runtime
  end

  def booted_with_accounts
    runtime = build
    open_accounts(runtime)
    runtime
  end

  # AccountsByKind is a real corpus report (banking.bluebook), proving
  # this feature against an already-model-checked domain.
  it "reads a whole aggregate's own table in bulk, no id argument, nested by one field", :aggregate_failures do
    grouped = accounts_by_kind(booted_with_accounts)

    expect(grouped.keys.sort).to eq(%w[current savings])
    expect(grouped["current"].keys.sort).to eq(%w[a1 a3])
    expect(grouped["savings"].keys).to eq(["a2"])
  end

  it "unwraps single-attribute value objects on the grouped head's own rows" do
    row = accounts_by_kind(booted_with_accounts)["current"]["a1"]

    # `number`/`kind` are group_by fields, already spent as keys, so they
    # don't survive into the leaf. `daily_limit` isn't part of group_by,
    # so it's the field left to check: a bare Integer, not `{cents: 0}`.
    expect(row[:daily_limit]).to eq(0)
  end

  # Proves multi-field group_by nesting end-to-end.
  it "nests by several fields, one level per field, in declared order" do
    runtime = boot_memory_domain("Nested", NESTED_GROUP_DOMAIN, aggregates: ["Gadget"])
    GADGET_REFS.each { |ref, group| Nested::Gadget.declare!(ref: { value: ref }, group: { value: group }) }

    expect(runtime.query("Nested.grouped").first[:gadgets]).to eq(GROUPED_BY_GROUP_AND_REF)
  end

  # ADR 0061 D1: a group_by leaf holds one row. Two rows sharing a full
  # key path refuse at dispatch; a key path covering the grouped
  # aggregate's own identity is accepted from the declaration.
  describe "a key path two rows share" do
    def boot_colliding
      runtime = boot_memory_domain("Collide", COLLIDING_DOMAIN, aggregates: ["Sprocket"])
      GADGET_REFS.each { |ref, group| Collide::Sprocket.declare!(ref: { value: ref }, group: { value: group }) }
      runtime
    end

    it "refuses, naming the read model, the key path and the colliding ids" do
      expect { boot_colliding.query("Collide.by_group") }
        .to raise_error(Hecks::Runtime::InvariantViolation, COLLISION_MESSAGE)
    end

    it "answers when the key path covers the grouped aggregate's identity" do
      grouped = boot_colliding.query("Collide.by_group_and_ref").first[:sprockets]

      expect(grouped).to eq(GROUPED_BY_GROUP_AND_REF)
    end

    it "accepts an identity-covering key path from the declaration alone", :aggregate_failures do
      bluebook = boot_colliding.registry.bluebook("Collide")
      sprocket = bluebook.aggregate("Sprocket")

      expect(bluebook.read_model("ByGroupAndRef").groups_by_identity?(sprocket)).to be(true)
      expect(bluebook.read_model("ByGroup").groups_by_identity?(sprocket)).to be(false)
    end
  end

  it "refuses group_by naming a field the aggregate doesn't declare" do
    registry = booted_with_accounts.registry

    expect { Hecks::Runtime::ReadModelInterpreter.new(registry).send(:project, "Banking", unknown_field_model(registry), {}) }
      .to raise_error(ArgumentError, /no_such_field.*declares no such attribute/m)
  end

  # AccountsByKind regrouped by a field the Account aggregate does not declare.
  def unknown_field_model(registry)
    model = registry.bluebook("Banking").read_model("AccountsByKind")
    Hecks::Bluebook::ReadModel.new(
      name: model.name, reference_name: nil, reference_target: nil,
      aggregate_heads: model.aggregate_heads, group_by: [{ field: :no_such_field }]
    )
  end

  it "refuses group_by declared with zero many-side heads" do
    expect(&domain_build("Rootful", ROOTFUL_GROUP_DOMAIN))
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /declares group_by but includes 0 many-side/)
  end

  it "refuses group_by declared with more than one many-side head" do
    expect(&domain_build("Crowded2", CROWDED_GROUP_DOMAIN))
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /declares group_by but includes 2 many-side/)
  end

  # Proves group_by applies through Sqlite's own boot, reusing
  # open_accounts already set up above.
  it "applies group_by through Sqlite's own boot too, by skipping the native escape hatch", :aggregate_failures do
    Dir.mktmpdir do |dir|
      grouped = accounts_by_kind(sqlite_with_accounts(dir))

      # "a1" is number's own unwrapped key (see the in-memory unwrap
      # test); daily_limit is the field still present to check here.
      expect([grouped.keys.sort, grouped["current"]["a1"][:daily_limit]]).to eq([%w[current savings], 0])
    end
  end
end
