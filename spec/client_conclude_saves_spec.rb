require "spec_helper"

# What concluding the invented bakery's interview gives to save in the client's own repo: the
# record and the bluebook, as relative paths, and nothing for a path under this repo's docs.
RSpec.describe "Concluding a client interview" do
  def concluded(interview)
    require "hecks/clients/concluded_files"
    Hecks::Clients::ConcludedFiles.call(interview)
  end

  let(:interview) do
    { reference: "INT-BAKE-1", subject: "rye and rosemary bakery", keeping: "local",
      exchanges: [{ speaker: "Baker", answer: "We take an order for a loaf.", question: "What happens?" }],
      points: [{ number: 1, kind: "thing", statement: "An order is a request for loaves.",
                 source: 1, status: "accepted" }] }
  end
  let(:files) { concluded(interview) }

  it "gives the record and the bluebook for the client's repo" do
    expect(files.keys).to eq(["interviews/INT-BAKE-1.md", "bluebook/RyeAndRosemaryBakery.bluebook"])
  end

  it "writes the record as the interview's Markdown and the bluebook as its accepted points" do
    expect(files.values).to eq([Hecks::Interviews::ConcludedRecord.text(interview),
                                Hecks::SME::DiscoveryProjection.text(subject: interview[:subject],
                                                                     points:  interview[:points])])
  end

  it "names no path under docs/ of this repo" do
    expect(files.keys.grep(%r{\A/|docs/|\.\.})).to be_empty
  end

  it "refuses an interview of Hecks's own, which is kept in docs/interviews" do
    expect { concluded(interview.merge(keeping: "committed")) }
      .to raise_error(ArgumentError, /committed/)
  end

  it "refuses a reference that is not one plain file name" do
    expect { concluded(interview.merge(reference: "../x")) }
      .to raise_error(ArgumentError, /plain file name/)
  end
end
