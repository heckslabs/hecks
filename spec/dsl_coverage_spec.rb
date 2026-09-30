require "hecks"
# `Hecks.behaviors` is opt-in but becomes a real, permanent singleton method once
# loaded anywhere in the process — required here directly so this file's coverage
# list is correct regardless of load order elsewhere in the suite.
require "hecks/behaviors"

RSpec.describe "the DSL surface is fully covered" do
  PLUMBING = %i[initialize build].freeze

  COVERED = {
    "Hecks (module surface)"      => [
      Hecks.singleton_class,
      # `boot_files` is Loader.boot_files's explicit-file sibling of `boot`; `behaviors`
      # is opt-in but becomes a real singleton method once anything requires it.
      %i[boot boot_files with_registry bluebook hecksagon port adapter world data_translation current_registry
         as_caller behaviors]
    ],
    "BluebookBuilder"             => [
      Hecks::Bluebook::DSL::BluebookBuilder,
      # `attaches_to`/`aggregate` are covered by their `_impl` dispatch targets; `namespace` is
      # tested in spec/chapter_namespace_spec.rb.
      %i[vision formerly_known_as namespace attaches_to_impl provides_impl core supporting generic aggregate_impl report
         read_model policy
         process_manager classification resolve_pending_chapter_givens! resolve_pending_chapter_entity_givens!]
    ],
    "AggregateBuilder"            => [
      Hecks::Bluebook::DSL::AggregateBuilder,
      # These DSL words are covered by their `_impl` dispatch targets, not the bare names.
      %i[description provenance_impl identified_by reference_to_impl has_many_impl has_one_impl belongs_to_impl
         value_object command_impl lifecycle_impl entity_impl query_impl policy_impl attribute list_of attributes
         invariant_impl given_impl projects_impl]
    ],
    "ValueObjectBuilder"          => [
      Hecks::Bluebook::DSL::ValueObjectBuilder,
      # Covered by their `_impl` dispatch targets, same as elsewhere in this table.
      %i[invariant_impl one_of_impl member_impl attribute list_of attributes]
    ],
    "CommandBuilder"              => [
      Hecks::Bluebook::DSL::CommandBuilder,
      # Covered by their `_impl` dispatch targets, reached via `GenericDispatch`'s
      # `calls:` — including `delegates_to_impl`/`corrects_impl`, documented at
      # their own definitions.
      %i[role_impl goal provenance_impl reference_to_impl given_impl ensures then_set_impl sets_impl
         delegates_to_impl corrects_impl emits state attribute list_of attributes]
    ],
    "PortBuilder"                 => [
      Hecks::Bluebook::DSL::PortBuilder,
      %i[verb signal answers]
    ],
    "DomainPortBuilder"           => [
      Hecks::Bluebook::DSL::DomainPortBuilder,
      # `tells`/`asks` are `_impl` dispatch targets; both "operation" and "tells"
      # Keyword rows name `tells_impl` in `calls:`, so `operation` is not a
      # directly-defined method here.
      %i[tells_impl asks_impl answers_query_impl verb signal answers]
    ],
    "PortOperationBuilder"        => [
      Hecks::Bluebook::DSL::PortOperationBuilder,
      # `reference_to` is covered by `reference_to_impl`.
      %i[reference_to_impl emits attribute list_of attributes]
    ],
    "AdapterBuilder"              => [
      Hecks::Bluebook::DSL::AdapterBuilder,
      %i[port field secret]
    ],
    "WorldBuilder"                => [
      Hecks::Bluebook::DSL::WorldBuilder,
      # `realm`/`latest`/`default_database`/`default_adapter` are `_impl` dispatch
      # targets, reached through `WordGate#word_gate_dispatch` from this class's own
      # `method_missing`. `record_binding` keeps `WorldConstProxy`'s writes on the
      # same path as the bare top-level spelling.
      %i[realm_impl latest_impl default_database_impl default_adapter_impl method_missing record_binding]
    ],
    "SettingsCollector"           => [
      Hecks::Bluebook::DSL::SettingsCollector,
      %i[method_missing to_h]
    ],
    "BindingProxy"                => [
      Hecks::Bluebook::DSL::BindingProxy,
      %i[port method_missing to_s]
    ],
    "WorldConstProxy"             => [
      # The `.world` file's ConstShim bridge — mirrors `BindingProxy`'s job for
      # `.hecksagon` files, minus the aggregate-qualifier bookkeeping `IR::World`
      # never reads back out.
      Hecks::Bluebook::DSL::WorldConstProxy,
      %i[method_missing]
    ],
    "HecksagonBuilder"            => [
      Hecks::Bluebook::DSL::HecksagonBuilder,
      # `port` is covered by `port_impl`. `translates` has no `_impl` split — Ruby's
      # own method lookup finds it directly — and is tested in spec/hecksagon_translates_spec.rb.
      # `attaches` is tested in spec/hecksagon_attaches_spec.rb.
      %i[binds subscribe subscriptions port_impl uses_framework framework_members
         uses_embryonaut_bluebook vendored_bluebooks attaches attached_chapters translates bounded method_missing]
    ],
    "TranslationBuilder"          => [
      Hecks::Bluebook::DSL::TranslationBuilder,
      # `aggregate` is covered by `aggregate_impl`.
      %i[aggregate_impl]
    ],
    "TranslationAggregateBuilder" => [
      Hecks::Bluebook::DSL::TranslationAggregateBuilder,
      # These are all covered by their `_impl` dispatch targets.
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
      # `identified_by` (S9, ADR 0025) is shared by AggregateBuilder and EntityBuilder
      # via IdentityDeclaration, same reason attribute/list_of/attributes are exempted here.
      stale = declared - actual - %i[attributes list_of attribute identified_by]

      expect(stale).to be_empty,
                       "#{label} declares #{stale.inspect} which no longer exists — remove it"
    end
  end

  it "AttributeCollector has no method without a test" do
    actual = Hecks::Bluebook::DSL::AttributeCollector.public_instance_methods(false)
    # `attribute` is not a real method any builder answers directly — `GenericDispatch`
    # forwards it to `attribute_impl`. `list_of`/`one_of` are `_impl` targets too, reached
    # through `WordGate#word_gate_dispatch`'s "Type"-context fallback.
    expect(actual.sort).to eq(%i[attribute_impl attributes closed_sets list_of_impl one_of_impl].sort)
  end

  # S9, ADR 0025 — `identified_by` lives in its own module so only AggregateBuilder
  # and EntityBuilder (its two includers) answer it, not every attribute()-taking builder.
  it "IdentityDeclaration has no method without a test" do
    actual = Hecks::Bluebook::DSL::IdentityDeclaration.public_instance_methods(false)
    # `identified_by` is covered by `identified_by_impl`, the same shared-mixin
    # dispatch shape as `attribute_impl`.
    expect(actual.sort).to eq(%i[identified_by_impl].sort)
  end

  it "ConstShim has no method without a test" do
    actual = Hecks::Bluebook::DSL::ConstShim.singleton_methods(false).sort
    expect(actual).to eq(%i[active? resolver resolver= with].sort)
  end

  it "every method_missing has a matching respond_to_missing?" do
    [
      Hecks::Bluebook::DSL::WorldBuilder,
      Hecks::Bluebook::DSL::SettingsCollector,
      Hecks::Bluebook::DSL::BindingProxy,
      Hecks::Bluebook::DSL::WorldConstProxy
    ].each do |klass|
      expect(klass.public_instance_methods(false)).to include(:method_missing),
                                                      "#{klass} should answer to anything"
      expect(klass.private_instance_methods(false)).to include(:respond_to_missing?),
                                                       "#{klass} lies to respond_to? without this"
    end
  end

  it "builds no runtime surface at all — the door is the facade's, at bind" do
    # A build produces only IR, so there is nothing left to keep `define_readers`/
    # `define_command` private for; the public surface is a per-boot projection
    # installed by Loader.bind_runtime.
    builder = Hecks::Bluebook::DSL::AggregateBuilder

    surface = builder.instance_methods(false) + builder.private_instance_methods(false)
    expect(surface).not_to include(:define_readers, :define_command, :nest_value_objects)
  end
end
