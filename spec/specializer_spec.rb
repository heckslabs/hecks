require "spec_helper"

RSpec.describe "the first specializer" do
  # `Specializer` speaks only for scalar, non-reference fields, so the comparison is against
  # the plain subset of the hand-written table, not the whole of it.
  %w[Policy Handler].each do |category|
    it "derives #{category}'s plain fields exactly as hand-written" do
      derived = Hecks::Bluebook::Assembly::Specializer.fields_for(category)
      hand    = Hecks::Bluebook::Assembly.contract(category).fields
                                         .select { |_name, (_source, mark)| mark == :plain }

      expect(derived).to eq(hand)
    end

    # Deriving the plain fields only counts if it derives all of them.
    it "leaves no plain field of #{category}'s for the hand-written table alone to carry" do
      derived = Hecks::Bluebook::Assembly::Specializer.fields_for(category)
      plain   = Hecks::Bluebook::Assembly.contract(category).fields
                                         .select { |_name, (_source, mark)| mark == :plain }.keys

      expect(derived.keys).to match_array(plain)
    end
  end
end
