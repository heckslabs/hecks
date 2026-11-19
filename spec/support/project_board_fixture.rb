# frozen_string_literal: true

require "fileutils"
require "json"
require "sqlite3"
require "tmpdir"

# Another project's checkout under a temporary directory: a local world naming a Tickets store
# beside it, and the store laid out as the SQLite adapter keeps it (a value object as
# `{"value": ...}`, a list as a JSON array). Nothing outside the directory is touched.
module ProjectBoardFixture
  WORLD = <<~WORLD
    Hecks.world "Shop" do
      persisted_by("SqlitePersistence") do
        database "%<dir>s/shop.db"
      end
    end

    Hecks.world "Tickets" do
      persisted_by("SqlitePersistence") do
        database "%<dir>s/tickets.db"
      end
    end
  WORLD

  module_function

  # @param projects [String] the directory the projects' checkouts sit in
  # @param works [Array<Array>] `[slug, status, step, epic]` each
  # @return [String] the checkout `shorts` under `projects`, with its world and store
  def checkout(projects, works:, epics: [["growth", "Grow", "More shorts"]])
    root = File.join(projects, "shorts")
    FileUtils.mkdir_p(File.join(root, "bluebook"))
    File.write(File.join(root, "bluebook", "shorts.local.world"), format(WORLD, dir: projects))
    store(File.join(projects, "tickets.db"), works, epics)
    root
  end

  def store(path, works, epics)
    db = SQLite3::Database.new(path)
    db.execute('CREATE TABLE "work" (id TEXT PRIMARY KEY, "work" TEXT, "title" TEXT, "status" TEXT, "step" TEXT, ' \
               '"epic" TEXT, "area" TEXT)')
    db.execute('CREATE TABLE "epic" (id TEXT PRIMARY KEY, "epic" TEXT, "title" TEXT, "outcome" TEXT)')
    works.each { |row| db.execute('INSERT INTO "work" VALUES (?, ?, ?, ?, ?, ?, ?)', work_cells(*row)) }
    epics.each { |row| db.execute('INSERT INTO "epic" VALUES (?, ?, ?, ?)', [row.first, *wrapped(*row)]) }
    db.close
  end

  def work_cells(slug, status, step, epic)
    [slug, *wrapped(slug, slug.tr("-", " ")), status, JSON.generate(value: step), epic && JSON.generate(value: epic),
     JSON.generate([{ value: "bluebook" }])]
  end

  def wrapped(*values) = values.map { |value| JSON.generate(value: value) }
end
