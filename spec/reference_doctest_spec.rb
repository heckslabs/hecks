
require "spec_helper"
require_relative "support/doctest"
require_relative "support/doctest_names"

# THE REFERENCE'S EXAMPLES RUN, the same way the guides' do. Presence is
# spec/reference_golden_spec.rb's question — every live word carrying an
# example at all — and this is the other half: that the example works.
# Either alone is worth little. A word can carry a fence that has never
# been executed, and a page of executed fences can still leave half the
# language undocumented.
#
# A page boots ONCE, in its hand-written preamble (the prose between the
# page's generated lede and its first word heading), and every word's
# example below runs against that boot — `Doctest::Session#waves` groups
# a run of declaration blocks with every usage block that follows it.
# Pages load the real corpus rather than inventing chapters, so the
# examples document a language somebody actually ships.
RSpec.describe "the DSL reference's examples" do
  DoctestNames.reference.each do |path|
    page = Doctest.parse(path)

    it "#{File.basename(path)} says nothing its examples cannot back", io: page.postgres do
      skip "no reachable Postgres — start one to run this page" if page.postgres && !Doctest::POSTGRES_AVAILABLE

      expect(Doctest.run(path)).to be(true)
    end
  end
end
