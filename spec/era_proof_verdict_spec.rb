require "spec_helper"
require "open3"

# The verdict the era proof gate check reads from a rehearsal outcome, run through the same jq
# filter the check runs. Fixture-only: no database and no rehearsal, so it runs anywhere jq does.
RSpec.describe "the era proof verdict" do
  let(:filter) { File.expand_path("../.github/era_proof/verdict.jq", __dir__) }

  def passes?(fixture)
    path = File.expand_path("fixtures/era_proof/#{fixture}", __dir__)
    _out, _err, status = Open3.capture3("jq", "-e", "-f", filter, path)
    status.success?
  end

  {
    "would_mint.json"         => true,
    "no_change.json"          => true,
    "verdict_no_change.json"  => true,
    "wrapped_would_mint.json" => true,
    "would_refuse.json"       => false,
    "needs_edge.json"         => false,
    "cannot_boot.json"        => false,
    "empty_copy.json"         => false,
    "missing_verdict.json"    => false,
    "padded_verdict.json"     => false,
    "empty_array.json"        => false
  }.each do |fixture, pass|
    it "#{pass ? "passes" : "fails"} #{fixture}" do
      expect(passes?(fixture)).to be(pass)
    end
  end
end
