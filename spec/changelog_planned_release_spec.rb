require "spec_helper"

# The user names the pending release while changes accumulate by writing it on the Unreleased
# heading: `## [Unreleased] - planned 3.11.0`. The release checks read only `## [X.Y.Z]`
# headings (release.yml, Release::Runner::Preflight, the Codebase release facts), so the
# annotation never reaches them; this pins the shape those readers rely on.
RSpec.describe "CHANGELOG.md planned release" do
  let(:lines)   { File.read(File.join(InMemoryDomain::ROOT, "CHANGELOG.md")).lines.map(&:chomp) }
  let(:heading) { lines.find { |line| line.start_with?("## [") } }
  let(:latest)  { lines.filter_map { |line| line[/\A## \[(\d+\.\d+\.\d+)\]/, 1] }.first }

  def key(version) = version.split(".").map(&:to_i)

  it "puts the Unreleased heading first, optionally naming the planned version", :aggregate_failures do
    expect(heading).to match(/\A## \[Unreleased\]( - planned \d+\.\d+\.\d+)?\z/)
  end

  it "plans a version later than the latest release" do
    planned = heading[/planned (\d+\.\d+\.\d+)/, 1] || "999.0.0"

    expect(key(planned) <=> key(latest)).to eq(1)
  end

  it "leaves the Unreleased heading invisible to a version heading check" do
    expect(heading).not_to match(/\A## \[\d+\.\d+\.\d+\]/)
  end
end
