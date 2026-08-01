require "spec_helper"

RSpec.describe "the first specializer" do
  %w[Policy Handler].each do |category|
    it "derives #{category}'s fields exactly as hand-written" do
      derived = Hecksagain::Bluebook::Assembly::Specializer.fields_for(category)
      hand    = Hecksagain::Bluebook::Assembly.contract(category).fields

      expect(derived).to eq(hand)
    end
  end
end
