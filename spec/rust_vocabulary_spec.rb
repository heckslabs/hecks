require "spec_helper"

# THE ANTI-DRIFT GATE for rust/src/kernel/vocab/ — the same shape
# spec/vocabulary_table_spec.rb uses for lib/hecks/vocabulary.rb:
# re-project in memory from vocabulary.bluebook and refuse a diff, so a
# committed Rust table that stopped matching the language fails the
# ordinary suite, not only CI's checks_codegen_drift regeneration.
RSpec.describe "the generated Rust vocabulary tables (bin/project_rust_vocabulary)" do
  let(:kernel) { File.join(InMemoryDomain::ROOT, "rust/src/kernel") }
  let(:projected) do
    Hecks::Projector.call(
      :rust_vocabulary,
      bluebook: Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
    )
  end

  it "is exactly what bin/project_rust_vocabulary would regenerate right now" do
    stale = projected.reject do |relative, content|
      path = File.join(kernel, relative)
      File.exist?(path) && File.read(path) == content
    end

    expect(stale.keys).to be_empty,
                          "#{stale.keys.join(', ')} drifted from vocabulary.bluebook — run bin/project_rust_vocabulary"
  end

  it "leaves no committed file under vocab/ that the projection no longer emits" do
    committed = Dir.glob(File.join(kernel, "vocab", "*.rs")).map { |path| "vocab/#{File.basename(path)}" }

    expect(committed - projected.keys).to be_empty
  end

  it "names the refusal templates in the same order Runtime::RefusalWording declares them" do
    source = projected.fetch("vocab/refusal_template.rs")
    variants = source[/pub enum RefusalSite \{(.*?)\}/m, 1].scan(/(\w+),/).flatten
    expected = Hecks::Runtime::RefusalWording::TEMPLATES.keys.map do |pair|
      pair.map { |part| part.split("_").map { |word| word[0].upcase + word[1..] }.join }.join
    end

    expect(variants).to eq(expected)
  end
end
