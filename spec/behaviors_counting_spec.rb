# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/behaviors_counting"

RSpec.describe Hecks::Adapters::BehaviorsCounting do
  let(:root) { Dir.mktmpdir("behaviors-counting") }
  let(:answer) { described_class.new(root: root).count(run: "r") }

  before do
    %w[with/a.bluebook with/a.behaviors without/b.bluebook fixtures/c.bluebook].each do |name|
      FileUtils.mkdir_p(File.dirname(File.join(root, name)))
      File.write(File.join(root, name), "")
    end
  end

  after { FileUtils.remove_entry(root) }

  it "names only the bluebook with no .behaviors file" do
    expect(answer[:report][:value]).to eq("without/b.bluebook")
  end

  it "counts the missing and the total, leaving a fixtures directory out", :aggregate_failures do
    expect(answer[:missing]).to eq(value: 1)
    expect(answer[:total]).to eq(value: 2)
  end

  it "says none lacks one when every bluebook has its file" do
    File.write(File.join(root, "without/b.behaviors"), "")
    expect(answer[:report][:value]).to eq("every bluebook has a .behaviors file")
  end

  it "counts the root a request names in place of its own" do
    other = described_class.new(root: "/nowhere").count(run: "r", root: { value: root })
    expect(other[:total]).to eq(value: 2)
  end
end
