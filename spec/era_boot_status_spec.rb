require "spec_helper"
require "open3"

# The era proof gate's verdict on one `era.boot_status` answer, run through the same jq filter the
# gate runs. Fixture-only: no database and no query, so it runs anywhere jq does.
RSpec.describe "the era proof boot status" do
  let(:filter) { File.expand_path("../.github/era_proof/boot_status.jq", __dir__) }

  def problems(fixture)
    path = File.expand_path("fixtures/era_boot_status/#{fixture}", __dir__)
    Open3.capture2("jq", "-r", "-f", filter, path).first
  end

  it "passes a current bluebook" do
    expect(problems("current.json")).to eq("")
  end

  it "passes a behind bluebook whose implicit move is recorded" do
    expect(problems("behind_recorded.json")).to eq("")
  end

  it "fails a behind bluebook with no recorded move, naming the reason" do
    expect(problems("behind_unrecorded.json")).to include("no implicit move is recorded from 541955 to 7005ea")
  end

  it "fails an unminted bluebook, naming the not-minted reason" do
    expect(problems("unminted.json")).to include("unminted: the ledger holds no shape for QualityControl")
  end

  it "fails a superseded bluebook, naming the reason" do
    expect(problems("superseded.json")).to include("superseded: the current shape e6b119 is older")
  end
end
