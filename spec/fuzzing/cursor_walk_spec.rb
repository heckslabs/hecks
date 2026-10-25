require "spec_helper"
require "hecks/fuzzing"
require_relative "../support/postgres_probe"
require "pg"

# `cursor_walk_yields_the_unpaged_rows` over Banking's `OpenPaged` (ADR 0130): twenty-seven open
# accounts take two pages of 25, and the replay also walks them one row at a time, so a page
# boundary falls between every pair of rows on every adapter it boots.
RSpec.describe "walking a cursor query by its pages" do
  def banking = File.join(InMemoryDomain::ROOT, "examples/banking")

  def steps
    register = { "verb" => "Banking::Customer.Register",
                 "args" => { "reference" => { "value" => "C-1" }, "name" => { "given" => "A", "family" => "B" },
                             "email" => { "address" => "a@example.com" } } }
    opens = (1..27).to_a.shuffle(random: Random.new(3)).map { |n| open_step(format("A-%02d", n)) }
    [register, *opens, { "query" => "Banking::Account.OpenPaged", "args" => {} }]
  end

  def open_step(number)
    { "verb" => "Banking::Account.Open",
      "args" => { "customer" => "C-1", "number" => { "value" => number }, "kind" => { "name" => "current" },
                  "daily_limit" => { "cents" => 1_000 } } }
  end

  def finding(history) = Hecks::Fuzzing::Properties.cursor_walk_yields_the_unpaged_rows(history)

  def walks(history) = history[:queries].last[:pages]

  %i[memory sqlite].each do |adapter|
    describe "on #{adapter}" do
      let(:history) { Hecks::Fuzzing::Replay.call(banking, steps, adapter: adapter) }

      it "yields exactly the unpaged rows, in order, at the query's page size and one row at a time",
         :aggregate_failures do
        expect(walks(history).map { |walk| walk[:pages].map(&:length) })
          .to eq([[25, 2], [1] * 27])
        expect(finding(history)).to be(true)
      end

      it "names a walk that drops a row" do
        walk = walks(history).first
        walk[:pages].first.pop
        expect(finding(history)).to be_a(String).and include("Banking::Account.OpenPaged", "page size 25")
      end

      it "names a walk that repeats a row" do
        walk = walks(history).last
        walk[:pages][1] = walk[:pages][0]
        expect(finding(history)).to be_a(String).and include("page size 1")
      end
    end
  end

  describe "on PostgresEra", :io do
    let(:database) { "hecks_cursor_walk_#{Process.pid}" }

    before do
      skip "no reachable Postgres" unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{database} WITH (FORCE)")
      admin.exec("CREATE DATABASE #{database}")
      admin.close
    end

    after do
      next unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{database} WITH (FORCE)")
      admin.close
    end

    it "yields exactly the unpaged rows at both page sizes" do
      history = Hecks::Fuzzing::Replay.call(banking, steps, adapter: :postgres_era, database: database, schema: "public")
      expect(finding(history)).to be(true)
    end
  end
end
