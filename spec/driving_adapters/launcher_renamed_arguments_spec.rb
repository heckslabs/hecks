require "spec_helper"

RSpec.describe Hecks::Adapters::Driving::LauncherRenamedArguments do
  let(:launcher) { { renamed_arguments: { "chapter" => "bluebook" } } }
  let(:spec) { { arguments: [{ path: "domain.value" }, { path: "bluebook.value" }] } }

  it "reads a retired argument as the one that replaced it, saying so", :aggregate_failures do
    words = nil

    expect { words = described_class.apply(spec, %w[domain.value=x chapter.value=Shelf], launcher) }
      .to output(/argument chapter is deprecated, use bluebook/).to_stderr
    expect(words).to eq(%w[domain.value=x bluebook.value=Shelf])
  end

  it "respells the short form of a value object too", :aggregate_failures do
    words = nil

    expect { words = described_class.apply(spec, %w[chapter=Shelf], launcher) }.to output.to_stderr
    expect(words).to eq(%w[bluebook=Shelf])
  end

  it "leaves a command that still declares the old name alone", :aggregate_failures do
    kept = { arguments: [{ path: "chapter.value" }] }

    expect { expect(described_class.apply(kept, %w[chapter.value=Shelf], launcher)).to eq(%w[chapter.value=Shelf]) }
      .not_to output.to_stderr
  end

  it "leaves the words alone when the launcher renames nothing", :aggregate_failures do
    expect(described_class.apply(spec, %w[chapter.value=Shelf], nil)).to eq(%w[chapter.value=Shelf])
    expect(described_class.apply(spec, %w[chapter.value=Shelf], {})).to eq(%w[chapter.value=Shelf])
  end

  it "leaves flags and words that are not pairs alone", :aggregate_failures do
    expect(described_class.apply(spec, %w[--chapter Shelf], launcher)).to eq(%w[--chapter Shelf])
  end
end
