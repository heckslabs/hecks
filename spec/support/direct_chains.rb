require "hecks"

# The committed translation edges and the chains they walk, as the direct translation spec proves
# them and `Lineage::DirectVerified` fingerprints them.
module DirectChains
  EDGE_DIRS = %w[lib/hecks/hecks qa/bluebook examples/pizzas/bluebook examples/directory/bluebook].freeze

  module_function

  # Every committed edge, grouped by domain.
  def edges_by_domain
    registry = Hecks::Runtime::Registry.new
    files = EDGE_DIRS.flat_map { |dir| Dir[File.join(Dir.pwd, dir, "translations", "*.bluebook")] }
    Hecks.with_registry(registry) { files.each { |file| Kernel.load(file) } }
    registry.translations.group_by(&:domain)
  end

  # The edges from `start` to `final`, or nil when no chain walks there.
  def walk(edges, domain, start, final)
    Hecks::Translation::Compose.chain(edges, domain: domain, from: start, to: final)
  rescue Hecks::Runtime::WiringError
    nil
  end

  # One [domain, start label, final label, edges] per start that walks to a chain end; Directory's
  # rekey has no exact composition and is covered on its own.
  def chains
    edges_by_domain.except("Directory").flat_map { |domain, edges| chains_of(domain, edges) }
  end

  def chains_of(domain, edges)
    pairs = edges.map(&:from).uniq.product(edges.map(&:to) - edges.map(&:from))
    walked = pairs.map { |start, final| [domain, start, final, walk(edges, domain, start, final)] }
    walked.select { |*_, chain| chain&.any? }
  end
end
