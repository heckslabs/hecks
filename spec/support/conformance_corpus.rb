require "json"
require "hecks/cli/seed_semantics_corpus"

# Locates the conformance corpus: language-neutral fixtures (`domain`, `steps`, frozen `expect`)
# that every runtime is held to. Shared by spec/conformance_corpus_spec.rb (Ruby) and
# spec/rust_conformance_spec.rb (Rust).
module ConformanceCorpus
  module_function

  # @return [Array<String>] absolute paths of every conformance fixture and full script
  def paths
    Hecks::CLI::SeedSemanticsCorpus.corpus_paths(InMemoryDomain::ROOT).select(&:last).map(&:first).sort
  end

  # @param path [String] a fixture path from {paths}
  # @return [Hash] the parsed fixture
  def load(path) = JSON.parse(File.read(path))
end
