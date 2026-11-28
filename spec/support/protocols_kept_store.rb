require "tmpdir"
require "hecks/hecks/adapters/local_overlaying/local_overlay"

# Boots the Protocols bluebook with its own registry over one SQLite store under a directory, as
# the checkout's overlay binds it: the hecksagon is the overlay's own text, so it names exactly
# the `KeptAggregate` rows.
module ProtocolsKeptStore
  ADAPTER  = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")
  BLUEBOOK = File.join(InMemoryDomain::ROOT, "lib/hecks/protocols/protocols.bluebook")
  PORTS    = [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
              InMemoryDomain::PRISM_ADAPTER, ADAPTER].freeze

  # @param root [String] the directory the store and its two files live in
  # @param rows [Array<Hash>] the `KeptAggregate` rows of the Hecks bluebook
  # @return [Object] the runtime bound to a new registry
  def self.boot(root, rows)
    registry = Hecks::Runtime::Registry.new
    files = [*PORTS, BLUEBOOK, *files(root, rows)]
    Hecks.with_registry(registry) { files.each { |file| Kernel.load(file) } }
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def self.files(root, rows)
    overlay = Hecks::Adapters::LocalOverlay.new(root, rows, "main").text
    [write(root, "protocols.hecksagon", overlay[/^Hecks\.hecksagon "Protocols" do.*?^end/m]),
     write(root, "protocols.world", world(root))]
  end

  def self.write(root, name, text) = File.join(root, name).tap { |path| File.write(path, text) }

  def self.world(root)
    "Hecks.world \"Protocols\" do\n  persisted_by(\"SqlitePersistence\") " \
      "{ database #{File.join(root, "protocols.db").inspect} }\nend\n"
  end
end
