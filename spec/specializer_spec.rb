require "spec_helper"

RSpec.describe "the first specializer" do
  # **What it claims, and only that**. `Specializer` speaks for fields that
  # are scalar and not references — its own header says so at length, and
  # says that a list is exactly what `contracts.rb`'s `reads:` exists to
  # answer instead. So the comparison is against the plain subset of the
  # hand-written table, not the whole of it.
  #
  # Written as whole-table equality first, which held only for as long as
  # neither checked category declared a list. `Policy` gaining
  # `with_spec` (a `trigger`'s own `with:` bindings, read through
  # `Marks#bindings` exactly as `Dispatch`'s already were) turned this
  # green-by-luck into a failure that said nothing true: the specializer
  # had not regressed, and the contract had not drifted — the claim was
  # just wider than the thing making it.
  %w[Policy Handler].each do |category|
    it "derives #{category}'s plain fields exactly as hand-written" do
      derived = Hecks::Bluebook::Assembly::Specializer.fields_for(category)
      hand    = Hecks::Bluebook::Assembly.contract(category).fields
                                         .select { |_name, (_source, mark)| mark == :plain }

      expect(derived).to eq(hand)
    end

    # **The other half of the same claim**. Deriving the plain fields is only
    # worth anything if it derives all of them — a specializer that
    # silently skipped one would pass the comparison above by matching a
    # table it had itself shrunk.
    it "leaves no plain field of #{category}'s for the hand-written table alone to carry" do
      derived = Hecks::Bluebook::Assembly::Specializer.fields_for(category)
      plain   = Hecks::Bluebook::Assembly.contract(category).fields
                                         .select { |_name, (_source, mark)| mark == :plain }.keys

      expect(derived.keys).to match_array(plain)
    end
  end
end
