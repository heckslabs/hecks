
require "spec_helper"
require "hecksagain/doc/reference"

# The reference pages must equal what the language declares — the same
# frozen-file discipline the golden IR carries, aimed at documentation.
# The tables are projected from the Syntax chapter; the prose is
# hand-written between markers and harvested through regeneration; and
# a tree where the two disagree refuses here rather than drifting
# quietly.
#
# Regenerate deliberately, never casually:
#
#     bin/reference        (or GOLDEN=rewrite this spec)
#
# The second gate is COVERAGE: a live (admitted or deprecated) word with
# no prose is a word the language ships undocumented, and that is a
# failure, not a TODO.
RSpec.describe "the DSL reference" do
  REFERENCE_DIR = File.join(InMemoryDomain::ROOT, "docs/reference").freeze

  it "matches what the language declares, page for page" do
    if ENV["GOLDEN"] == "rewrite"
      Hecksagain::Doc::Reference.write!(REFERENCE_DIR)
      skip "rewrote docs/reference/"
    end

    Hecksagain::Doc::Reference.pages(REFERENCE_DIR).each do |name, content|
      path = File.join(REFERENCE_DIR, name)
      expect(File.exist?(path))
        .to be(true), "no #{name} — the language declares a context the reference does not carry; run bin/reference"
      expect(File.read(path))
        .to eq(content), "the language and docs/reference/#{name} disagree — run bin/reference and review the diff"
    end
  end

  it "lets no live word ship undocumented" do
    missing = Hecksagain::Doc::Reference.undocumented(REFERENCE_DIR)
    expect(missing).to be_empty,
                       "#{missing.size} live words carry no prose — write their sections:\n  " +
                       missing.join("\n  ")
  end

  it "carries README's own generated indexes, undrifted" do
    path = File.join(InMemoryDomain::ROOT, "README.md")

    if ENV["GOLDEN"] == "rewrite"
      Hecksagain::Doc::Reference.write_readme!(InMemoryDomain::ROOT)
      skip "rewrote README.md"
    end

    expect(File.read(path))
      .to eq(Hecksagain::Doc::Reference.render_readme(InMemoryDomain::ROOT, File.read(path))),
          "README.md's generated regions (guides/reference/corpus/tools) disagree with what's on " \
          "disk — run bin/reference and review the diff"
  end
end
