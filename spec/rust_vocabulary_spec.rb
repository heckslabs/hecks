require "spec_helper"
require "hecks/rust_format"

# The anti-drift gate for rust/src/kernel/vocab/ — the same shape
# spec/vocabulary_table_spec.rb uses for lib/hecks/vocabulary.rb:
# re-project in memory from vocabulary.bluebook and refuse a diff, so a
# committed Rust table that stopped matching the language fails the
# ordinary suite, not only CI's checks_codegen_drift regeneration.
RSpec.describe "the generated Rust vocabulary tables (hecks project_rust_vocabulary)" do
  let(:kernel) { File.join(InMemoryDomain::ROOT, "rust/src/kernel") }
  let(:projected) do
    files = Hecks::Projector.call(
      :rust_vocabulary,
      bluebook: Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    )
    Hecks::RustFormat.files(files)
  end

  def stale_files
    projected.reject do |relative, content|
      path = File.join(kernel, relative)
      File.exist?(path) && File.read(path) == content
    end
  end

  it "is exactly what hecks project_rust_vocabulary would regenerate right now" do
    stale = stale_files

    expect(stale.keys).to be_empty,
                          "#{stale.keys.join(", ")} drifted from vocabulary.bluebook — run hecks project_rust_vocabulary"
  end

  it "leaves no committed file under vocab/ that the projection no longer emits" do
    committed = Dir.glob(File.join(kernel, "vocab", "*.rs")).map { |path| "vocab/#{File.basename(path)}" }

    expect(committed - projected.keys).to be_empty
  end

  it "escapes every reserved word a field could take, including the 2018 keywords", :aggregate_failures do
    escaped = %w[async await match].map { |word| Hecks::Projections::RustVocabulary.field_name(word) }

    expect(escaped).to eq(%w[r#async r#await r#match])
  end
end
