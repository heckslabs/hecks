require "spec_helper"

RSpec.describe FacadeConstantIsolation do
  let(:module_for) { ->(label) { Module.new { define_singleton_method(:label) { label } } } }

  after { Hecks::Namespace::GENERATED.delete([Object, "IsolationProbe"]) }

  it "removes a facade constant installed after the snapshot" do
    before = described_class.snapshot
    Hecks::Namespace.install(Object, "IsolationProbe", module_for.call(:late))

    described_class.restore(before)

    expect(Object.const_defined?(:IsolationProbe, false)).to be false
    expect(Hecks::Namespace::GENERATED).not_to have_key([Object, "IsolationProbe"])
  end

  it "puts back the module a later install replaced" do
    original = Hecks::Namespace.install(Object, "IsolationProbe", module_for.call(:original))
    before = described_class.snapshot
    Hecks::Namespace.install(Object, "IsolationProbe", module_for.call(:replacement))

    described_class.restore(before)

    expect(Object.const_get(:IsolationProbe, false)).to equal(original)
  ensure
    Object.send(:remove_const, :IsolationProbe) if Object.const_defined?(:IsolationProbe, false) # rubocop:disable RSpec/RemoveConst
  end
end
