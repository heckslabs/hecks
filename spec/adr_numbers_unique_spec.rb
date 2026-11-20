require "spec_helper"

# One number names one decision. Two ADRs sharing a number make "ADR 0054" ambiguous in every
# comment and doc that cites it, and the Adr store leaves both out, so a duplicate fails here,
# across docs/decisions and docs/implemented/decisions together.
RSpec.describe "architecture decision records" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:duplicated) do
    Dir.glob(File.join(root, "docs/{,implemented/}decisions/[0-9][0-9][0-9][0-9]-*.md"))
       .group_by { |path| File.basename(path)[/\A\d{4}/] }
       .select { |_number, paths| paths.size > 1 }
       .keys
       .sort
  end

  it "gives every decision its own number" do
    expect(duplicated).to be_empty,
                          "these ADR numbers are used twice; take the next free number for one of each: " \
                          "#{duplicated.join(", ")}"
  end
end
