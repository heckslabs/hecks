# THE RULE, ENFORCED.
#
# "A test for every method in the DSL" is worth nothing as an intention. This
# discovers the DSL surface BY REFLECTION and fails when a method exists that
# has not been declared as covered — so adding one without a test breaks the
# suite in the same commit, rather than a month later when nobody remembers.
#
# Declaring a method here is a promise that spec/dsl_spec.rb exercises it. The
# list is deliberately hand-maintained: an automatic "it appears somewhere in
# the spec file" check passes on a mention in a comment, which is how coverage
# gates come to mean nothing.
require "hecksagain"

RSpec.describe "the DSL surface is fully covered" do
  # Constructors and terminals — exercised by every single example, never
  # interesting on their own.
  PLUMBING = %i[initialize build].freeze

  # Each entry: the class or module, and the methods spec/dsl_spec.rb exercises.
  COVERED = {
    "Hecksagain (module surface)" => [
      Hecksagain.singleton_class,
      %i[boot with_registry bluebook hecksagon family adapter world current_registry]
    ],
    "BluebookBuilder" => [
      Hecksagain::Bluebook::DSL::BluebookBuilder,
      %i[vision core supporting generic aggregate classification]
    ],
    "AggregateBuilder" => [
      Hecksagain::Bluebook::DSL::AggregateBuilder,
      %i[description identified_by reference_to value_object command attribute list_of attributes]
    ],
    "ValueObjectBuilder" => [
      Hecksagain::Bluebook::DSL::ValueObjectBuilder,
      %i[invariant attribute list_of attributes]
    ],
    "CommandBuilder" => [
      Hecksagain::Bluebook::DSL::CommandBuilder,
      %i[role goal reference_to given then_set emits attribute list_of attributes]
    ],
    "FamilyBuilder" => [
      Hecksagain::Bluebook::DSL::FamilyBuilder,
      %i[verb signal field secret]
    ],
    "AdapterBuilder" => [
      Hecksagain::Bluebook::DSL::AdapterBuilder,
      %i[family]
    ],
    "WorldBuilder" => [
      Hecksagain::Bluebook::DSL::WorldBuilder,
      %i[method_missing]
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
      # Public instance methods defined ON this class, not inherited.
      actual = subject.public_instance_methods(false) - PLUMBING
      actual -= %i[collector collector=] # class-level state, exercised via hecksagon

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

  # AttributeCollector is mixed in rather than inherited, so its methods show up
  # on the three builders that include it — checked there. This asserts the
  # mixin itself has not grown a fourth method nobody noticed.
  it "AttributeCollector has no method without a test" do
    actual = Hecksagain::Bluebook::DSL::AttributeCollector.public_instance_methods(false)
    expect(actual.sort).to eq(%i[attribute attributes list_of].sort)
  end

  it "ConstShim has no method without a test" do
    actual = Hecksagain::Bluebook::DSL::ConstShim.singleton_methods(false).sort
    expect(actual).to eq(%i[active? resolver resolver= with].sort)
  end

  # Ruby makes respond_to_missing? PRIVATE automatically, the way it does
  # initialize — so it is not public surface and cannot be declared above. It is
  # still behaviour worth pinning: every method_missing needs its matching
  # respond_to_missing?, or the object lies to respond_to?.
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

  # The private helpers that construct the Ruby class are implementation, not
  # surface — asserted private so they cannot quietly become part of the DSL.
  it "class construction stays private" do
    builder = Hecksagain::Bluebook::DSL::AggregateBuilder

    expect(builder.private_instance_methods(false)).to include(:define_readers, :define_command)
    expect(builder.public_instance_methods(false)).not_to include(:define_readers, :define_command)
  end
end
