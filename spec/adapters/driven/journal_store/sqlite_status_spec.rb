# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "sqlite3"
require "hecks/hecks/adapters/journal_store"

# The SQLite status reading on temp databases: drift and orphans are reported, and the file is
# never written, so the reading shows what an adapter open would change without doing it.
RSpec.describe Hecks::Adapters::JournalStore::Readings::SqliteStatus do
  let(:store) { Hecks::Adapters::JournalStore.new }
  let(:database) { File.join(@dir, "shop.db") }

  around do |example|
    @dir = Dir.mktmpdir("hecks-sqlite-status-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  before do
    File.write(File.join(@dir, "shop.bluebook"), <<~RUBY)
      Hecks.bluebook "Shop" do
        aggregate "Pot" do
          attribute :label, Label
          attribute :size, Size
          identified_by :label
          value_object "Label" do
            attribute :value, String, matches: :present
          end
          value_object "Size" do
            attribute :value, Integer
          end
          command "Fill" do
            attribute :label, Label
          end
        end
        aggregate "Revision" do
          formerly_known_as "Commit"
          attribute :message, Message
          identified_by :message
          value_object "Message" do
            attribute :value, String, matches: :present
          end
          command "Make" do
            attribute :message, Message
          end
        end
      end
    RUBY
    File.write(File.join(@dir, "shop.hecksagon"), <<~RUBY)
      Hecks.hecksagon "Shop" do
        Shop::Pot.persisted_by("SqlitePersistence")
        Shop::Revision.persisted_by("SqlitePersistence")
      end
    RUBY
    File.write(File.join(@dir, "shop.world"), <<~RUBY)
      Hecks.world "Shop" do
        persisted_by("SqlitePersistence") do
          database "#{database}"
        end
      end
    RUBY
    lay_older_tables!
  end

  # Pot lacks its `size` column; Revision's rows sit in the table its former name made, beside a
  # table nothing maps to.
  def lay_older_tables!
    db = SQLite3::Database.new(database)
    db.execute(%(CREATE TABLE "pot" (id TEXT PRIMARY KEY, label TEXT)))
    db.execute(%(CREATE TABLE "commit" (id TEXT PRIMARY KEY, message TEXT)))
    db.execute(%(CREATE TABLE "revision" (id TEXT PRIMARY KEY, message TEXT)))
    db.execute(%(CREATE TABLE "stray_notes" (id TEXT PRIMARY KEY, body TEXT, extra TEXT)))
    db.close
  end

  def status = JSON.parse(store.sqlite_status(domain: @dir)[:text], symbolize_names: true)

  def tables = status.first[:tables].to_h { |row| [row[:aggregate], row] }

  it "reports a column the aggregate declares and the table lacks" do
    expect(tables["Pot"]).to include(state: "drift", missing: ["size"])
  end

  it "keeps a renamed aggregate's table under its former name and finds it whole" do
    expect(tables["Revision"]).to include(aggregate: "Revision", table: "commit", state: "ok")
  end

  it "reports an orphan table, naming the aggregate whose own name it carries" do
    orphans = status.first[:orphans]
    expect(orphans).to include({ table: "revision", belongs_to: "Revision", stored_as: "commit" },
                               { table: "stray_notes" })
  end

  it "writes nothing: the file's bytes and modification time are unchanged" do
    before_bytes = File.binread(database)
    before_time = File.mtime(database)
    status
    expect([File.binread(database), File.mtime(database)]).to eq([before_bytes, before_time])
  end
end
