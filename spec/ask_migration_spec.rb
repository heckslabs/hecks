require "spec_helper"
require "hecks/cli"
require "hecks/cli/model_check"

# ADR 0100's waves: a chapter file listed here has moved its port-naming triggers to `ask`, and
# a new `trigger Aggregate::Port::Operation` in it is refused, so the leak cannot grow back.
RSpec.describe "files migrated to ask" do
  # Wave 1 is the Tooling chapter; each later wave adds its files here.
  ASK_MIGRATED_FILES = %w[lib/hecks/hecks/tooling.bluebook].freeze

  def chapter_of(file)
    registry = Hecks::CLI::ModelCheck.boot(File.join(InMemoryDomain::ROOT, File.dirname(file)))
    registry.bluebook(File.read(File.join(InMemoryDomain::ROOT, file))[/Hecks\.bluebook "(\w+)"/, 1])
  end

  def port_triggers_in(file)
    chapter = chapter_of(file)
    names = File.read(File.join(InMemoryDomain::ROOT, file)).scan(/^\s*policy "(\w+)"/).flatten
    chapter.policies.select { |policy| names.include?(policy.name) }
           .select { |policy| Hecks::Bluebook::ModelCheck.ask_finding(chapter, policy)&.kind == :port_trigger }
           .map(&:name)
  end

  ASK_MIGRATED_FILES.each do |file|
    it "keeps #{file} free of a trigger that names a port operation" do
      expect(port_triggers_in(file)).to eq([])
    end
  end

  it "lists only files that exist" do
    expect(ASK_MIGRATED_FILES.select { |file| File.exist?(File.join(InMemoryDomain::ROOT, file)) }).to eq(ASK_MIGRATED_FILES)
  end
end
