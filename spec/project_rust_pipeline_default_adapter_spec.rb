require "spec_helper"
require "tmpdir"
require_relative "../rust/project_rust_pipeline"

# The opt-in Rust pipeline derives an aggregate's adapter from text, not from a booted registry
# (rust/project_rust_pipeline.rb::derive_lineage), so a world's `default_adapter` needs its own
# text scan. `rust/build/src/lineage_pass.rs` carries the line-for-line twin, with the same
# fixture under `cargo test`.
RSpec.describe "the opt-in pipeline's reading of a world's default_adapter" do
  def adapter_in(text, chapter)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "domain.world")
      File.write(path, text)
      RustProjectPipeline.default_adapter_name(path, chapter)
    end
  end

  let(:worlds) do
    <<~WORLDS
      Hecks.world "Alpha" do
        # default_adapter "Heki"
        default_adapter "PostgresEra"
      end

      Hecks.world("Beta") do
        default_adapter "Memory"
      end
    WORLDS
  end

  it "reads the adapter the target chapter's own world declares" do
    expect(adapter_in(worlds, "Alpha")).to eq("PostgresEra")
  end

  it "reads a parenthesised world opener the same way" do
    expect(adapter_in(worlds, "Beta")).to eq("Memory")
  end

  it "answers nil for a chapter whose world declares none" do
    expect(adapter_in(worlds, "Gamma")).to be_nil
  end

  it "finds the sibling world file only when one exists" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bluebook"))
      expect(RustProjectPipeline.sibling_world_path(dir, "alpha")).to be_nil

      File.write(File.join(dir, "bluebook", "alpha.world"), worlds)
      expect(RustProjectPipeline.sibling_world_path(dir, "alpha")).to end_with("bluebook/alpha.world")
    end
  end
end
