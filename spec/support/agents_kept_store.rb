require "tmpdir"
require "hecks/hecks/adapters/main_integration/train"

# The files that bind the Agents bluebook's kept aggregates to one SQLite store under a directory,
# as the checkout's overlay does: the hecksagon is the overlay's own text, so it names exactly the
# `KeptAggregate` rows.
module AgentsKeptStore
  # @param root [String] the directory the store and its two files live in
  # @param rows [Array<Hash>] the `KeptAggregate` rows of the Hecks bluebook
  # @return [Array<String>] the world and the hecksagon files, to load after the bluebook
  def self.files(root, rows)
    overlay = Hecks::Adapters::MainIntegration::LocalOverlay.new(root, rows, "main").text
    [write(root, "agents.world", world(root)), write(root, "agents.hecksagon", overlay[/^Hecks\.hecksagon "Agents" do.*?^end/m])]
  end

  def self.write(root, name, text) = File.join(root, name).tap { |path| File.write(path, text) }

  def self.world(root)
    "Hecks.world \"Agents\" do\n  persisted_by(\"SqlitePersistence\") { database #{File.join(root, "agents.db").inspect} }\nend\n"
  end
end
