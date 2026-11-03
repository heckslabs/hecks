require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/behaviors/expectations/adapter_selection"

# A behaviors suite chooses its adapters without a list (ADR 0171): the project's adapters that say
# `stays_inside`, the stand-ins beside the suite, and never the code of an adapter that reaches out.
RSpec.describe Hecks::Behaviors::Expectations::AdapterSelection do
  def adapter(path, name, port, inside: false, requires: nil)
    lines = [(%(require_relative "#{requires}") if requires), %(Hecks.adapter "#{name}" do), %(  port "#{port}"),
             ("  stays_inside" if inside), "end"].compact
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{lines.join("\n")}\n")
  end

  # A project whose Thinker reaches outside and whose `require` would raise if it ever ran.
  def project(root, stand_in: true)
    adapter(File.join(root, "adapters/moments.adapter"), "Moments", "Mind", inside: true)
    adapter(File.join(root, "adapters/voice.adapter"), "Renderer", "Voice", inside: true)
    adapter(File.join(root, "adapters/thinker.adapter"), "Thinker", "Thinker", requires: "boom")
    File.write(File.join(root, "adapters", "boom.rb"), %(raise "the outside adapter's code ran"\n))
    adapter(File.join(root, "bluebook/behavior_adapters/voice.adapter"), "QuietVoice", "Voice") if stand_in
  end

  def chosen(root) = described_class.call(File.join(root, "bluebook", "x.behaviors"), [File.join(root, "bluebook", "x.bluebook")])

  def names(paths) = paths.map { |path| path.split("/").last(2).join("/") }

  it "loads the adapters that stay inside and the stand-ins, never the one that reaches outside" do
    Dir.mktmpdir do |root|
      project(root)
      expect(names(chosen(root))).to eq(%w[adapters/moments.adapter behavior_adapters/voice.adapter])
    end
  end

  it "leaves a project that has not opted in to the loader's own choice" do
    Dir.mktmpdir do |root|
      adapter(File.join(root, "adapters/thinker.adapter"), "Thinker", "Thinker")
      expect(chosen(root)).to be_nil
    end
  end

  it "loads the project's own adapter for a port no stand-in claims" do
    Dir.mktmpdir do |root|
      project(root, stand_in: false)
      expect(names(chosen(root))).to eq(%w[adapters/moments.adapter adapters/voice.adapter])
    end
  end
end
