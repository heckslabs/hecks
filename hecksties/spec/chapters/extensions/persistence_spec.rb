# Extensions::PersistenceChapter paragraph spec
#
# Verifies persistence-related aggregates exist within the Extensions domain.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions::PersistenceChapter do
  subject(:domain) { Hecks::Chapters::Extensions.definition }

  it "includes FilesystemRepository with Save, Load, and Delete commands" do
    agg = domain.aggregates.find { |a| a.name == "FilesystemRepository" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Save", "Load", "Delete")
  end

  it "includes FileAdapter with Write and Read commands" do
    agg = domain.aggregates.find { |a| a.name == "FileAdapter" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Write", "Read")
  end
end
