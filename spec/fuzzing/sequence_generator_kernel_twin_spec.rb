require "spec_helper"
require "hecks/fuzzing/sequence_generator"
require "hecks/corpus"
require_relative "../support/generated_rust"

# The gate of slice 3 of docs/plans/simulation-tests.md: for every in-repo domain with a Cargo
# feature, the same seed builds the same step list on the Ruby engine and on the kernel engine.
# A difference is reported as a finding, the first step where the lists part, never skipped.
# Coverage tuples are not compared: the kernel names a refusal `Refused` and answers no query yet.
RSpec.describe "Hecks::Fuzzing::SequenceGenerator on either engine (native binary)", :io do
  include_context "with the generated Rust tree"

  GENERATOR_TWIN_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  def kernel_binary(domain)
    Hecks::RustBuild::NativeBuild.build_rust_for(domain.feature, GENERATOR_TWIN_RUST_DIR) ||
      raise("rust/Cargo.toml has no #{domain.feature} feature")
  end

  # The first step where the two lists part, for the failure message.
  def finding(ruby, kernel)
    index = ruby.zip(kernel).index { |left, right| left != right } || [ruby.size, kernel.size].min
    JSON.pretty_generate("step" => index, "ruby" => ruby[index], "kernel" => kernel[index])
  end

  Hecks::Corpus.rust_domains.each do |domain|
    it "#{domain.feature}: the same seed gives the same steps on either engine" do
      ruby = Hecks::Fuzzing::SequenceGenerator.generate(domain.dir, seed: 1, steps: 20)
      kernel = Hecks::Fuzzing::SequenceGenerator.generate(domain.dir, seed: 1, steps: 20, engine: :kernel,
                                                                                   binary: kernel_binary(domain))
      expect(kernel).to eq(ruby), finding(ruby, kernel)
    end
  end
end
