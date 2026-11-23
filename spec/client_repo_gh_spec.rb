require "spec_helper"
require "hecks/clients/adapters/client_repo_gh"

# The `ClientRepo` adapter over `gh`, driven only with a fake command runner, so nothing is created
# or written anywhere. The repository is the invented bakery's.
RSpec.describe Hecks::Adapters::ClientRepoGh do
  let(:calls) { [] }
  let(:visibility) { "PRIVATE" }
  let(:runner) do
    lambda do |*argv|
      calls << argv
      argv[2] == "view" ? [{ nameWithOwner: "me/rye", visibility: visibility }.to_json, "", true] : ["", "", true]
    end
  end
  let(:adapter) { described_class.new(runner: runner) }
  let(:name) { { value: "Rye and Rosemary Bakery" } }

  it "creates the repository private, with no other visibility asked" do
    adapter.create_private(name: name)
    expect(calls.first).to eq(%w[gh repo create rye-and-rosemary-bakery --private])
  end

  it "has no method that takes a visibility" do
    parameters = described_class.instance_methods(false).flat_map { |m| described_class.instance_method(m).parameters }
    expect(parameters.map(&:last)).not_to include(:visibility, :public, :private)
  end

  it "writes a file to a repository that reads as private" do
    adapter.write_file(name: name, path: { value: "a.md" }, content: { value: "hi" })
    expect(calls.last.first(5)).to eq(%w[gh api -X PUT repos/me/rye/contents/a.md])
  end

  context "when the repository reads as public" do
    let(:visibility) { "PUBLIC" }

    it "refuses the write" do
      expect { adapter.write_file(name: name, path: { value: "a.md" }, content: { value: "hi" }) }
        .to raise_error(described_class::Refused, /is not private/)
    end

    it "runs nothing but the read" do
      adapter.write_file(name: name, path: { value: "a.md" }, content: { value: "hi" })
    rescue described_class::Refused
      expect(calls.map { |argv| argv[2] }).to eq(%w[view])
    end
  end

  it "refuses when gh fails" do
    failing = ->(*_argv) { ["", "boom", false] }
    expect { described_class.new(runner: failing).create_private(name: name) }.to raise_error(described_class::Refused, /boom/)
  end
end
