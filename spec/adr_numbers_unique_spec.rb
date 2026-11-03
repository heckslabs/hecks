require "spec_helper"

# One number names one decision. Two ADRs sharing a number make "ADR 0054" ambiguous in every
# comment and doc that cites it, so a new duplicate fails here. The pairs below predate this
# check and cannot be renumbered without rewriting every citation; the list only shrinks.
RSpec.describe "architecture decision records" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:known_duplicates) { %w[0018 0029 0030 0036 0054 0055 0058] }
  let(:duplicated) do
    Dir.glob(File.join(root, "docs/{,implemented/}decisions/[0-9][0-9][0-9][0-9]-*.md"))
       .group_by { |path| File.basename(path)[/\A\d{4}/] }
       .select { |_number, paths| paths.size > 1 }
       .keys
       .sort
  end

  it "gives every decision its own number" do
    expect(duplicated - known_duplicates).to be_empty,
                                             "these ADR numbers are used twice — take the next free number: " \
                                             "#{(duplicated - known_duplicates).join(", ")}"
  end

  it "drops a number from the known duplicates once it is unique again" do
    expect(known_duplicates - duplicated).to be_empty,
                                             "no longer duplicated, remove from known_duplicates: " \
                                             "#{(known_duplicates - duplicated).join(", ")}"
  end
end
