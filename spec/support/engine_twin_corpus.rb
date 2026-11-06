require "json"

# The corpus files the engine twin spec plays, and which of them the kernel under test can run.
module EngineTwinCorpus
  # The Cargo feature of the kernel binary the twin builds.
  FEATURE = "pizzas".freeze

  ROOT = File.expand_path("../..", __dir__)

  module_function

  # @return [Array<String>] every `spec/corpus/*.json` script
  def paths = Dir[File.join(ROOT, "spec/corpus/*.json")]

  # @param path [String] a corpus file
  # @return [String] the domain directory it drives, relative to the checkout
  def domain_of(path)
    JSON.parse(File.read(path)).fetch("domain") { "examples/#{File.basename(path, ".json")}" }
  end

  # @param path [String] a corpus file
  # @return [Array<Hash>] its steps
  def steps_of(path) = JSON.parse(File.read(path)).fetch("steps")

  # @param engine [#call] a Fuzzing engine
  # @param path [String] a corpus file
  # @return [Hash] the history the engine gives for the file's steps
  def history_through(engine, path) = engine.call(File.join(ROOT, domain_of(path)), steps_of(path))

  # @return [String] the corpus script for pizzas, the domain the kernel under test is built for
  def pizzas_path = File.join(ROOT, "spec/corpus/pizzas.json")

  # @param path [String] a corpus file
  # @return [String, nil] why the kernel under test cannot run it; nil when it can
  def skip_reason(path)
    domain = domain_of(path)
    return nil if File.basename(domain) == FEATURE

    "the kernel under test is the #{FEATURE} build; #{File.basename(path)} drives #{domain}"
  end
end
