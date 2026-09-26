require "spec_helper"
require "json"
require "tmpdir"
require_relative "../../rust/project"

# A framework chapter attached to a target domain never gets a `merged.rs`
# of its own, and `WriteIfChanged.track_directory` prunes any `merged.rs`
# an earlier run left in its directory. Its `mod.rs` therefore must not
# declare `pub mod merged;`, whatever the previous `mod.rs` said; a
# dangling declaration fails the next `cargo build` with E0583.
RSpec.describe RustProjection::DomainGenerator do
  let(:ir) do
    path = File.expand_path("../../rust/src/generated/compliance/ir.json", __dir__)
    JSON.parse(File.read(path), symbolize_names: true)
  end

  # Leaves `dir` the way a run that targeted the domain itself leaves it:
  # a `merged.rs` and a `mod.rs` that ends with `pub mod merged;`.
  def seed_previous_target_run(dir)
    described_class.call(ir, "spec", dir, "compliance")
    File.write(File.join(dir, "merged.rs"), "// merged\n")
    File.open(File.join(dir, "mod.rs"), "a") { |f| f.puts "pub mod merged;" }
  end

  it "drops the `pub mod merged;` trailer when the chapter is generated as a framework chapter" do
    Dir.mktmpdir("framework-chapter-mod") do |root|
      dir = File.join(root, "compliance")
      seed_previous_target_run(dir)

      RustProjection::WriteIfChanged.track_directory(dir) do
        described_class.call(ir, "spec (uses_framework \"Compliance\")", dir, "compliance", merged_module: false)
      end

      expect(File.exist?(File.join(dir, "merged.rs"))).to be(false)
      expect(File.read(File.join(dir, "mod.rs"))).not_to include("pub mod merged;")
    end
  end

  it "keeps the trailer when the caller writes a `merged.rs` beside the chapter" do
    Dir.mktmpdir("framework-chapter-mod") do |root|
      dir = File.join(root, "compliance")
      seed_previous_target_run(dir)

      described_class.call(ir, "spec", dir, "compliance")

      expect(File.read(File.join(dir, "mod.rs"))).to include("pub mod merged;")
    end
  end
end
