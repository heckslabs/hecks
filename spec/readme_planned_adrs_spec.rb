require "spec_helper"

# A decision record cannot be both built and unbuilt. The README's "Planned or research
# only" list says nothing below it is built, so an ADR linked from that list must not
# carry an "implemented" status in its own header. When the two disagree, one section
# of the README reads as landed while the next says "not yet implemented".
RSpec.describe "README's planned-or-research-only list" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:readme) { File.read(File.join(root, "README.md")) }
  let(:planned) { readme[%r{^\*\*Planned or research only.*?(?=^\[`docs/future-features)}m] }
  let(:adr_paths) do
    planned.to_s.scan(%r{\(docs/decisions/([^)#]+\.md)\)}).flatten.uniq
  end

  it "has a planned list to check" do
    expect(planned).not_to be_nil, "README no longer has a 'Planned or research only' list"
  end

  it "links no ADR whose own status says it is implemented" do
    contradicted = adr_paths.select do |file|
      status = File.read(File.join(root, "docs/decisions", file))[/^\*\*Status:\*\*[^\n]*/]
      status.to_s =~ /\bimplemented\b/i && status !~ /\b(not|partially)\s+(yet\s+)?implemented\b/i
    end

    expect(contradicted).to be_empty,
                            "README lists #{contradicted.join(', ')} as planned, but the ADR's " \
                            "own Status line says it is implemented — drop it from the list"
  end
end
