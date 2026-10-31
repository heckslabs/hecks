require "spec_helper"
require "hecks/rendering"
require "hecks/runtime/refusal_wording"

# A refusal quotes an offered value as `Rendering.describe` wrote it, backslashes included: the
# Rust kernel renders the same template by literal replacement, and `check_conformance` compares
# the two texts (BUG#152).
RSpec.describe Hecks::Runtime::RefusalWording do
  def creating_duplicate(offered)
    described_class.render_site("AlreadyExists", "creating_duplicate",
                                command: "Open", aggregate: "Folder", identity: "reference.value",
                                offered: Hecks::Rendering.describe(offered))
  end

  it "keeps the backslash a described value carries" do
    expect(creating_duplicate("with a \\backslash"))
      .to eq("Open creates a Folder that already exists — reference.value \"with a \\\\backslash\"")
  end

  it "inserts a value holding a gsub back-reference as written" do
    expect(creating_duplicate("a\\&b\\0c"))
      .to eq("Open creates a Folder that already exists — reference.value \"a\\\\&b\\\\0c\"")
  end

  it "substitutes every marker literally" do
    expect(described_class.substitute("{a} and {b}", a: "\\1", b: "\\\\")).to eq("\\1 and \\\\")
  end
end
