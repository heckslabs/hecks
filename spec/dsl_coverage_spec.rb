require "hecksagain"

RSpec.describe "the DSL surface is fully covered" do
  PLUMBING = %i[initialize build].freeze

  COVERED = {
    "Hecksagain (module surface)" => [
      Hecksagain.singleton_class,
      %i[boot with_registry bluebook hecksagon port adapter world data_translation current_registry as_caller]
    ],
    "BluebookBuilder"             => [
      Hecksagain::Bluebook::DSL::BluebookBuilder,
      # `attaches_to`/`aggregate` -> `*_impl` — item #13's full
      # metaprogrammed dispatch (slice 4c).
      %i[vision formerly_known_as attaches_to_impl core supporting generic aggregate_impl report read_model policy
         process_manager classification]
    ],
    "AggregateBuilder"            => [
      Hecksagain::Bluebook::DSL::AggregateBuilder,
      # `has_many`/`has_one`/`belongs_to`/`given`/`invariant`/
      # `reference_to` (slices 4/4b) and `provenance`/`identified_by`/
      # `lifecycle`/`entity`/`query`/`policy`/`command`/`projects`
      # (slice 4c) -> `*_impl` — item #13's full metaprogrammed
      # dispatch, same reasoning as role_impl throughout.
      %i[description provenance_impl identified_by reference_to_impl has_many_impl has_one_impl belongs_to_impl
         value_object command_impl lifecycle_impl entity_impl query_impl policy_impl attribute list_of attributes
         invariant_impl given_impl projects_impl]
    ],
    "ValueObjectBuilder"          => [
      Hecksagain::Bluebook::DSL::ValueObjectBuilder,
      # `invariant`/`member` -> `*_impl`, same reasoning, slices 4b/4c.
      %i[invariant_impl one_of member_impl attribute list_of attributes]
    ],
    "CommandBuilder"              => [
      Hecksagain::Bluebook::DSL::CommandBuilder,
      # `role`/`given`/`reference_to` (slices 4/4b) and `provenance`/
      # `sets` (slice 4c) -> `*_impl` — item #13's full metaprogrammed
      # dispatch. GenericDispatch forwards via calls:; these are the
      # real, directly-defined methods.
      %i[role_impl goal provenance_impl reference_to_impl given_impl ensures then_set sets_impl emits attribute
         list_of attributes]
    ],
    "PortBuilder"                 => [
      Hecksagain::Bluebook::DSL::PortBuilder,
      %i[verb signal]
    ],
    "DomainPortBuilder"           => [
      Hecksagain::Bluebook::DSL::DomainPortBuilder,
      # `tells`/`asks` -> `*_impl` — item #13's full metaprogrammed
      # dispatch (slice 4c). `operation` is a Ruby `alias` no more —
      # both "operation" and "tells" Keyword rows name `tells_impl` in
      # `calls:` now, so `operation` no longer shows up here as a
      # directly-defined method at all.
      %i[tells_impl asks_impl]
    ],
    "PortOperationBuilder"        => [
      Hecksagain::Bluebook::DSL::PortOperationBuilder,
      # `reference_to` -> `reference_to_impl`, same reasoning, slice 4b.
      %i[reference_to_impl emits attribute list_of attributes]
    ],
    "AdapterBuilder"              => [
      Hecksagain::Bluebook::DSL::AdapterBuilder,
      %i[port field secret]
    ],
    "WorldBuilder"                => [
      Hecksagain::Bluebook::DSL::WorldBuilder,
      %i[realm latest method_missing]
    ],
    "SettingsCollector"           => [
      Hecksagain::Bluebook::DSL::SettingsCollector,
      %i[method_missing to_h]
    ],
    "BindingProxy"                => [
      Hecksagain::Bluebook::DSL::BindingProxy,
      %i[port method_missing to_s]
    ],
    "HecksagonBuilder"            => [
      Hecksagain::Bluebook::DSL::HecksagonBuilder,
      %i[binds subscribe subscriptions port uses_framework framework_members
         uses_embryonaut_bluebook vendored_bluebooks method_missing]
    ],
    "TranslationBuilder"          => [
      Hecksagain::Bluebook::DSL::TranslationBuilder,
      # `aggregate` -> `aggregate_impl`, slice 4c.
      %i[aggregate_impl]
    ],
    "TranslationAggregateBuilder" => [
      Hecksagain::Bluebook::DSL::TranslationAggregateBuilder,
      # `unresolved` (slice 4) and `rename`/`move`/`convert`/`retype`/
      # `compute`/`rekey`/`backfill` (slice 4c) -> `*_impl`.
      %i[rename_impl move_impl convert_impl retype_impl compute_impl rekey_impl backfill_impl unresolved_impl]
    ]
  }.freeze

  COVERED.each do |label, (subject, declared)|
    it "#{label} has no method without a test" do
      actual = subject.public_instance_methods(false) - PLUMBING
      actual -= %i[collector collector=]

      undeclared = actual - declared

      expect(undeclared).to be_empty,
                            "#{label} gained #{undeclared.inspect} with no example in dsl_spec.rb — " \
                            "add one, then declare it here"
    end

    it "#{label} declares nothing that has been removed" do
      actual = subject.public_instance_methods(false) + PLUMBING
      # `identified_by` (S9, ADR 0025) — shared by AggregateBuilder and
      # EntityBuilder via IdentityDeclaration, the same reason
      # attribute/list_of/attributes are already exempted here for
      # AttributeCollector.
      stale = declared - actual - %i[attributes list_of attribute identified_by]

      expect(stale).to be_empty,
                       "#{label} declares #{stale.inspect} which no longer exists — remove it"
    end
  end

  it "AttributeCollector has no method without a test" do
    actual = Hecksagain::Bluebook::DSL::AttributeCollector.public_instance_methods(false)
    # `attribute` -> `attribute_impl` — item #13's full metaprogrammed
    # dispatch (slice 3, whole-project table-unification survey): the
    # word `attribute` is no longer a real method any builder answers
    # directly, `GenericDispatch` forwards to this renamed one instead.
    expect(actual.sort).to eq(%i[attribute_impl attributes closed_sets list_of one_of].sort)
  end

  # S9, ADR 0025 — `identified_by`, split out of AttributeCollector into
  # its own module so only AggregateBuilder/EntityBuilder (its two real
  # includers) answer it, not every attribute()-taking builder.
  it "IdentityDeclaration has no method without a test" do
    actual = Hecksagain::Bluebook::DSL::IdentityDeclaration.public_instance_methods(false)
    # `identified_by` -> `identified_by_impl` — item #13's full
    # metaprogrammed dispatch (slice 4c), same shared-mixin shape
    # `attribute_impl` proved in slice 3.
    expect(actual.sort).to eq(%i[identified_by_impl].sort)
  end

  it "ConstShim has no method without a test" do
    actual = Hecksagain::Bluebook::DSL::ConstShim.singleton_methods(false).sort
    expect(actual).to eq(%i[active? resolver resolver= with].sort)
  end

  it "every method_missing has a matching respond_to_missing?" do
    [
      Hecksagain::Bluebook::DSL::WorldBuilder,
      Hecksagain::Bluebook::DSL::SettingsCollector,
      Hecksagain::Bluebook::DSL::BindingProxy
    ].each do |klass|
      expect(klass.public_instance_methods(false)).to include(:method_missing),
                                                      "#{klass} should answer to anything"
      expect(klass.private_instance_methods(false)).to include(:respond_to_missing?),
                                                       "#{klass} lies to respond_to? without this"
    end
  end

  it "builds no runtime surface at all — the door is the facade's, at bind" do
    # The builder used to keep `define_readers`/`define_command` private ; now
    # there is nothing to keep private, because a build produces only IR. The
    # public surface is a per-boot projection installed by Loader.bind_runtime.
    builder = Hecksagain::Bluebook::DSL::AggregateBuilder

    surface = builder.instance_methods(false) + builder.private_instance_methods(false)
    expect(surface).not_to include(:define_readers, :define_command, :nest_value_objects)
  end
end
