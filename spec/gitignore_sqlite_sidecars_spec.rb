require "spec_helper"
require "open3"
require_relative "support/protocols_kept_store"

# A Protocols write leaves the checkout clean: the agreement and vote stores keep a write-ahead log,
# and the `-wal` and `-shm` files beside them are ignored by the repository's own `.gitignore`.
RSpec.describe "the SQLite sidecar files of the Protocols stores" do
  let(:root) { Dir.mktmpdir("sidecars") }
  let(:rows) { Hecks::Adapters::MainIntegration::KeptRows.from_registry(boot_hecks_in_memory.registry) }

  before do
    FileUtils.cp(File.join(InMemoryDomain::ROOT, ".gitignore"), root)
    system("git", "init", "-q", root)
  end

  after { FileUtils.remove_entry(root) }

  def untracked_databases
    out, = Open3.capture2("git", "-C", root, "ls-files", "--others", "--exclude-standard")
    out.split("\n").grep(/\.db/)
  end

  it "ignores a -wal, -shm and -journal file beside a database", :aggregate_failures do
    %w[agreement.db-wal agreement.db-shm vote.db-journal].each { |name| FileUtils.touch(File.join(root, name)) }
    expect(untracked_databases).to be_empty
  end

  def enter_an_agreement
    ProtocolsKeptStore.boot(root, rows)
    Protocols::Agreement.propose!(reference: { value: "WA-1" }, text: { value: "Done means seen working" },
                                  proposer: { value: "scrum-master" }, affects: { value: "|coder|" },
                                  touches_owner: { value: "no" }, owed: { value: 1 })
  end

  it "leaves no untracked database file after an agreement is entered", :aggregate_failures do
    enter_an_agreement
    expect(Dir.children(root).grep(/-wal\z/)).not_to be_empty
    expect(untracked_databases).to be_empty
  end
end
