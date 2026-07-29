require "hecksagain"

RSpec.describe "the DSL surface is fully covered" do
  PLUMBING = %i[initialize build].freeze

  COVERED = {
    "Hecksagain (module surface)" => [
      Hecksagain.singleton_class,
      %i[boot with_registry bluebook hecksagon port adapter world current_registry]
    ],
    "BluebookBuilder" => [
      Hecksagain::Bluebook::DSL::BluebookBuilder,
      %i[vision core supporting generic aggregate read_model policy process_manager classification]
    ],
    "AggregateBuilder" => [
      Hecksagain::Bluebook::DSL::AggregateBuilder,
      %i[description identified_by reference_to value_object command lifecycle
         entity query policy attribute list_of attributes]
    ],
    "ValueObjectBuilder" => [
      Hecksagain::Bluebook::DSL::ValueObjectBuilder,
      %i[invariant one_of member attribute list_of attributes]
    ],
    "CommandBuilder" => [
      Hecksagain::Bluebook::DSL::CommandBuilder,
      %i[role goal reference_to given then_set emits attribute list_of attributes]
    ],
    "PortBuilder" => [
      Hecksagain::Bluebook::DSL::PortBuilder,
      %i[verb signal]
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
      %i[method_missing to_s]
    ],
    "HecksagonBuilder" => [
      Hecksagain::Bluebook::DSL::HecksagonBuilder,
      %i[binds]
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

  it "class construction stays private" do
    builder = Hecksagain::Bluebook::DSL::AggregateBuilder

    expect(builder.private_instance_methods(false)).to include(:define_readers, :define_command)
    expect(builder.public_instance_methods(false)).not_to include(:define_readers, :define_command)
  end
end
