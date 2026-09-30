require "spec_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require_relative "support/postgres_probe"
require_relative "support/fenced_owner"

# The Hecks domain's journal outlives the process. One process runs a journaled command through
# the launcher against a real Postgres; a second, started afterwards, reads it back with
# `hecks ask history` and `exe/hecks stores`. Needs a reachable Postgres.
RSpec.describe "the Hecks domain journals to PostgresEra", :io do
  JOURNAL_DB = "hecks_journal_survives_spec".freeze
  HECKS_ROOT = InMemoryDomain::ROOT

  SURVIVING_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shelf" do
      vision "Books on a shelf."

      aggregate "Book" do
        description "A book."
        attribute :title, Title
        identified_by :title

        value_object "Title" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a book is titled") { !value.to_s.empty? }
        end

        command "Shelve" do
          attribute :title, Title
          sets :title
          emits Shelved
        end
      end
    end
  RUBY

  LAUNCH_SCRIPT = <<~RUBY.freeze
    require "hecks"
    runtime = Hecks.boot(File.join(ARGV.fetch(0), "lib/hecks/hecks"), install_facade: false)
    text, status = Hecks::Facade::CliRunner.call(runtime: runtime, argv: ARGV.drop(1), program: "hecks")
    puts text
    exit status
  RUBY

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{JOURNAL_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{JOURNAL_DB}")
    admin.close
    FencedOwner.own!(JOURNAL_DB)
    @dir = Dir.mktmpdir("journal-survives-")
    FileUtils.mkdir_p(File.join(@dir, "shelf/bluebook"))
    File.write(File.join(@dir, "shelf/bluebook/shelf.bluebook"), SURVIVING_BLUEBOOK)
    File.write(File.join(@dir, "shelf/bluebook/shelf.hecksagon"),
               "Hecks.hecksagon \"Shelf\" do\n  persisted_by \"Memory\"\nend\n")
    File.write(File.join(@dir, "launch.rb"), LAUNCH_SCRIPT)
  end

  after(:all) do
    FileUtils.rm_rf(@dir) if @dir
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{JOURNAL_DB} WITH (FORCE)")
    admin.close
  end

  # A child process with no environment selected, so the domain binds its real store, and the
  # database named by `HECKS_DATABASE`.
  def child(*argv)
    env = { "HECKS_DATABASE" => FencedOwner.url(JOURNAL_DB), "HECKS_ENVIRONMENT" => nil,
            "HECKS_NO_3_0_NOTICE" => "1" }
    Open3.capture3(env, RbConfig.ruby, "-I#{File.join(HECKS_ROOT, 'lib')}", *argv, chdir: HECKS_ROOT)
  end

  it "keeps a journaled command's events for a later process" do
    out, err, status = child(File.join(@dir, "launch.rb"), HECKS_ROOT, "model_check", "run=kept-1",
                             "domains=#{File.join(@dir, 'shelf')}")
    expect(status.success?).to be(true), "#{out}\n#{err}"
    expect(JSON.parse(out).fetch("events")).to eq(["ModelCheckRequested"])

    history, err, status = child(File.join(@dir, "launch.rb"), HECKS_ROOT, "ask", "history",
                                 "domain=#{File.join(HECKS_ROOT, 'lib/hecks/hecks')}")
    expect(status.success?).to be(true), err
    entries = JSON.parse(history.lines.last).fetch("model_check_run")
    expect(entries.map { |entry| entry.fetch("operation") }).to eq(%w[save save])

    stores, err, status = child(File.join(HECKS_ROOT, "exe/hecks"), "stores", File.join(HECKS_ROOT, "lib/hecks/hecks"))
    expect(status.success?).to be(true), err
    runs = JSON.parse(stores.lines.last).fetch("model_check_run").fetch("authoritative")
    expect(runs.to_s).to include("kept-1")
  end
end
