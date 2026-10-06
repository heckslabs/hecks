require "spec_helper"
require "hecks/doc/reference"

# The reference pages must equal what the language declares: tables are projected from the
# Syntax chapter, prose is hand-written between markers, and every live word needs prose.
# Regenerate deliberately with `hecks language_run.project_reference` (or GOLDEN=rewrite).
RSpec.describe "the DSL reference" do
  REFERENCE_DIR = File.join(InMemoryDomain::ROOT, "docs/implemented/reference").freeze

  README_PATH = File.join(InMemoryDomain::ROOT, "README.md").freeze

  README_DRIFT = "README.md's generated regions (guides/reference/corpus/tools/diagrams) disagree with what's on " \
                 "disk — run hecks language_run.project_reference and review the diff".freeze

  # What is wrong with the committed page `name`, as a list of messages: empty when it equals
  # `content`.
  def page_problems(name, content)
    path = File.join(REFERENCE_DIR, name)
    unless File.exist?(path)
      return ["no #{name} — the language declares a context the reference does not carry; " \
              "run hecks language_run.project_reference"]
    end
    return [] if File.read(path) == content

    ["the language and docs/implemented/reference/#{name} disagree — " \
     "run hecks language_run.project_reference and review the diff"]
  end

  it "matches what the language declares, page for page" do
    if ENV["GOLDEN"] == "rewrite"
      Hecks::Doc::Reference.write!(REFERENCE_DIR)
      skip "rewrote docs/implemented/reference/"
    end

    expect(Hecks::Doc::Reference.pages(REFERENCE_DIR).flat_map { |name, content| page_problems(name, content) }).to be_empty
  end

  it "lets no live word ship undocumented" do
    missing = Hecks::Doc::Reference.undocumented(REFERENCE_DIR)
    expect(missing).to be_empty,
                       "#{missing.size} live words carry no prose — write their sections:\n  " +
                       missing.join("\n  ")
  end

  # Every live word must carry an example. Prose nothing runs cannot disagree with the
  # runtime it describes; whether the examples pass is spec/reference_doctest_spec.rb's question.
  it "lets no live word ship unexemplified" do
    missing = Hecks::Doc::Reference.unexemplified(REFERENCE_DIR)
    expect(missing).to be_empty,
                       "#{missing.size} live words carry no running example — write one in each " \
                       "word's own section:\n  " + missing.join("\n  ")
  end

  def regenerated_readme = Hecks::Doc::Reference.render_readme(InMemoryDomain::ROOT, File.read(README_PATH))

  it "carries README's own generated indexes, undrifted" do
    if ENV["GOLDEN"] == "rewrite"
      Hecks::Doc::Reference.write_readme!(InMemoryDomain::ROOT)
      skip "rewrote README.md"
    end

    expect(File.read(README_PATH)).to eq(regenerated_readme), README_DRIFT
  end
end
