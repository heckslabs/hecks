require "rubocop"
# Not "rubocop/rspec/support": its top-level RSpec.configure includes CopHelper into every
# example group, and CopHelper#registry collides with other specs' own `registry`.
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"

# What every spec of a Hecks RuboCop cop starts with: the cop under test as `cop`, built from a
# config that leaves the cop-name badge off so an offense message matches the cop's `MSG`.
# CopHelper extends RSpec::SharedContext, so RSpec must be loaded first.
RSpec.shared_context "with a Hecks cop under test" do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  subject(:cop) { described_class.new(config) }

  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }
end
