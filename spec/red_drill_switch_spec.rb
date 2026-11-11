# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "support/red_drill"

# The switch of the red drill is off unless the environment or a tracked file turns it on.
RSpec.describe RedDrill do
  def with_file(content)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "spec", "support"))
      File.write(File.join(root, RedDrill::FILE), content) if content
      yield root
    end
  end

  it "is off with neither the variable nor the file", :aggregate_failures do
    with_file(nil) { |root| expect(described_class.on?(env: {}, root: root)).to be(false) }
    with_file(nil) { |root| expect(described_class.on?(env: { "HECKS_RED_DRILL" => "0" }, root: root)).to be(false) }
  end

  it "is on when the variable is 1" do
    with_file(nil) { |root| expect(described_class.on?(env: { "HECKS_RED_DRILL" => "1" }, root: root)).to be(true) }
  end

  it "is on when the tracked file reads 1", :aggregate_failures do
    with_file("1\n") { |root| expect(described_class.on?(env: {}, root: root)).to be(true) }
    with_file("0\n") { |root| expect(described_class.on?(env: {}, root: root)).to be(false) }
  end

  it "ships off: the repository holds no switch file" do
    expect(described_class.on?(env: {})).to be(false)
  end

  it "defines no example in the drill spec while off" do
    expect(RSpec.world.example_groups.map(&:description)).not_to include("the red drill")
  end
end
