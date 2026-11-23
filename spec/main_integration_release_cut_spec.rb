require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration/range_guard"

# A boarding carries a change to the version file only as the commit the release cut made.
RSpec.describe Hecks::Adapters::MainIntegration::RangeGuard do
  let(:mark) { Hecks::Adapters::MainIntegration::ReleaseCutMark }
  let(:repository) { repository_class.new(["Release v7.2.0"], ["lib/hecks/version.rb"]) }
  # A repository that answers what the range says, whatever the range is.
  let(:repository_class) do
    Struct.new(:said, :touched) do
      def messages(*) = said
      def changed(*) = touched
    end
  end
  let(:tip) { "a" * 40 }

  let(:cache) { Dir.mktmpdir("hecks-cut-mark") }

  before { allow(Hecks::CacheDir).to receive(:path).and_return(cache) }

  after { FileUtils.rm_rf(cache) }

  it "refuses a version change no release cut made" do
    expect { described_class.new(repository).check!("b" * 40, tip) }.to raise_error(%r{changes lib/hecks/version.rb})
  end

  it "lets the commit the release cut made carry the version change" do
    mark.record(tip)

    expect { described_class.new(repository).check!("b" * 40, tip) }.not_to raise_error
  end

  it "no longer asks for an approval line in a message" do
    repository.said = ["Release v7.2.0\n\nRelease-Approved-By: Someone"]
    repository.touched = []

    expect { described_class.new(repository).check!("b" * 40, tip) }.not_to raise_error
  end
end
