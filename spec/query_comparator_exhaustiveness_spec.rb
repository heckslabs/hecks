require "spec_helper"

# The `else held == want` spec/query_comparators_spec.rb's own header
# describes as ALREADY the cause of one real, shipped silent-`eq` bug
# (gt/gte/lt/lte/ne/in/contains, before this table existed) is no longer a
# quiet fallback for a NEW, unrecognized comparator either — it refuses
# instead of guessing. A direct, no-boot unit test: the closed set itself
# (Vocabulary::QueryComparator) is exhaustively covered by
# query_comparators_spec.rb; this is the backstop for the tenth name.
RSpec.describe "Comparison.holds?, an unrecognized comparator" do
  it "refuses rather than silently comparing for equality" do
    expect do
      Hecks::QuerySpecification::Common::Comparison.holds?("starts_with", "abc", "a")
    end.to raise_error(Hecks::Runtime::WiringError, /no comparator handles "starts_with"/)
  end
end
