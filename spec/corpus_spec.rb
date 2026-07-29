
require "spec_helper"

# Every corpus member must LOAD.
#
# `bin/parity` is the only thing that reads the corpus, and it is hand-run —
# so a bluebook could stop parsing entirely and the suite people actually run
# would stay green. That happened: a new value-object rule landed, banking and
# pizzas were migrated to satisfy it, and `lib/hecksagain/grammar/expression.bluebook`
# was left behind. It raised `Malformed` at load, parity died before stage one,
# and rspec reported 358/358 the whole time — because nothing in spec/ booted
# the grammar chapter.
#
# This walks the SAME corpus `bin/parity` walks, derived the same way rather
# than listed, so a member added there is covered here without anyone
# remembering to add it.
RSpec.describe "The corpus" do
  # Mirrors bin/parity:99 — `for domain in "$ROOT"/examples/*/ "$ROOT"/lib/hecksagain/grammar/`
  DOMAIN_ROOTS = (
    Dir.glob(File.join(InMemoryDomain::ROOT, "examples", "*")).select { |path| File.directory?(path) } +
    [File.join(InMemoryDomain::ROOT, "lib/hecksagain/grammar")]
  ).sort.freeze

  # Mirrors bin/parity's bluebook lookup — prefer <domain>/bluebook/*.bluebook,
  # fall back to <domain>/*.bluebook.
  def self.bluebook_in(domain)
    Dir.glob(File.join(domain, "bluebook", "*.bluebook")).sort.first ||
      Dir.glob(File.join(domain, "*.bluebook")).sort.first
  end

  it "finds every domain bin/parity walks" do
    expect(DOMAIN_ROOTS).not_to be_empty
    expect(DOMAIN_ROOTS.map { |domain| self.class.bluebook_in(domain) }).to all(be_truthy)
  end

  DOMAIN_ROOTS.each do |domain|
    bluebook = bluebook_in(domain)
    next unless bluebook

    it "loads #{File.basename(bluebook)}" do
      registry = Hecksagain::Runtime::Registry.new

      expect do
        Hecksagain.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Kernel.load(bluebook)
        end
      end.not_to raise_error

      expect(registry.bluebooks).not_to be_empty
    end
  end
end
