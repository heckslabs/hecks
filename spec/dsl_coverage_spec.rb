require "hecksagain"

RSpec.describe "the DSL surface is fully covered" do
  PLUMBING = %i[initialize build].freeze

  COVERED = {
    "Hecksagain (module surface)" => [
      Hecksagain.singleton_class,
      %i[boot with_registry bluebook hecksagon port adapter world data_translation current_registry as_caller]
    ],
    "BluebookBuilder" => [
      Hecksagain::Bluebook::DSL::BluebookBuilder,
      %i[vision core supporting generic aggregate report read_model policy process_manager classification]
    ],
    "AggregateBuilder" => [
      Hecksagain::Bluebook::DSL::AggregateBuilder,
      %i[description provenance identified_by reference_to has_many has_one belongs_to value_object command lifecycle
         entity query policy attribute list_of attributes]
    ],
    "ValueObjectBuilder" => [
      Hecksagain::Bluebook::DSL::ValueObjectBuilder,
      %i[invariant one_of member attribute list_of attributes]
    ],
    "CommandBuilder" => [
      Hecksagain::Bluebook::DSL::CommandBuilder,
      %i[role goal provenance reference_to given ensures then_set sets emits attribute list_of attributes]
    ],
    "PortBuilder" => [
      Hecksagain::Bluebook::DSL::PortBuilder,
      %i[verb signal]
    ],
    "DomainPortBuilder" => [
      Hecksagain::Bluebook::DSL::DomainPortBuilder,
      %i[operation verb]
    ],
    "PortOperationBuilder" => [
      Hecksagain::Bluebook::DSL::PortOperationBuilder,
      %i[reference_to emits attribute list_of attributes]
    ],
    "AdapterBuilder" => [
      Hecksagain::Bluebook::DSL::AdapterBuilder,
      %i[port field secret]
    ],
    "WorldBuilder" => [
      Hecksagain::Bluebook::DSL::WorldBuilder,
      %i[realm latest method_missing]
    ],
    "SettingsCollector" => [
      Hecksagain::Bluebook::DSL::SettingsCollector,
      %i[method_missing to_h]
    ],
    "BindingProxy" => [
      Hecksagain::Bluebook::DSL::BindingProxy,
      %i[port method_missing to_s]
    ],
    "HecksagonBuilder" => [
      Hecksagain::Bluebook::DSL::HecksagonBuilder,
      %i[binds subscribe subscriptions port]
    ],
    "TranslationBuilder" => [
      Hecksagain::Bluebook::DSL::TranslationBuilder,
      %i[aggregate retired method_missing]
    ],
    "TranslationAggregateBuilder" => [
      Hecksagain::Bluebook::DSL::TranslationAggregateBuilder,
      %i[rename move convert drop retype compute unresolved method_missing]
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
      stale = declared - actual - %i[attributes list_of attribute]

      expect(stale).to be_empty,
                       "#{label} declares #{stale.inspect} which no longer exists — remove it"
    end
  end

  it "AttributeCollector has no method without a test" do
    actual = Hecksagain::Bluebook::DSL::AttributeCollector.public_instance_methods(false)
    expect(actual.sort).to eq(%i[attribute attributes closed_sets list_of one_of].sort)
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
