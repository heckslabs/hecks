require "spec_helper"
require "hecks/hecks/adapters/world_clearing"

RSpec.describe Hecks::Adapters::WorldClearing do
  let(:world) do
    <<~RUBY
      Hecks.world "Shop" do
        persisted_by("Postgres") do
          database "postgres://localhost/shop"
        end

        # Where the host deploys it.
        deployed_to("AwsBox") do
          region "us-east-1"
          routes [
            { container: "cms", paths: ["/cms/*"] }
          ]
          public_url "https://shop.example.com"
        end
      end
    RUBY
  end

  let(:cleared) { described_class.call(world) }

  it "names the settings it removed, once each, in order" do
    expect(cleared.settings).to eq(%w[region routes public_url])
  end

  it "keeps the opening and closing lines of the block" do
    expect(cleared.text).to include("  deployed_to(\"AwsBox\") do\n    # The host's deployment settings", "\n  end\nend\n")
  end

  it "leaves every line outside the block as it was" do
    expect(cleared.text.lines.first(6)).to eq(world.lines.first(6))
  end

  it "leaves no setting value behind" do
    expect(cleared.text).not_to include("us-east-1", "shop.example.com", "/cms/*")
  end

  it "folds the comment under 100 columns" do
    expect(cleared.text.lines.map { |line| line.chomp.size }.max).to be < 100
  end

  it "changes nothing the second time" do
    expect(described_class.call(cleared.text).text).to eq(cleared.text)
  end

  it "reports a second clearing as unchanged" do
    expect(described_class.call(cleared.text)).not_to be_changed
  end

  it "empties every block, not only the first" do
    twice = world + world.sub("Shop", "Other")

    expect(described_class.call(twice).text).not_to include("us-east-1")
  end

  it "ignores a deployed_to named in a comment" do
    expect(described_class.call("# deployed_to(\"AwsBox\") do\n#   region \"x\"\n# end\n")).not_to be_changed
  end

  it "leaves a world with no deployed_to block untouched" do
    expect(described_class.call("Hecks.world(\"A\") do\nend\n").text).to eq("Hecks.world(\"A\") do\nend\n")
  end
end
