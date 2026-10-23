require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"

# A `derive` means the same thing run in process and compiled into the Postgres head: every
# expression, over records that are missing, not text, empty, quoted or non-ASCII.
RSpec.describe "derive, run in process and compiled to Postgres", :io do
  DERIVE_DB = "hecks_derive_equivalence_spec".freeze

  DERIVE_EXPRESSIONS = [
    "lower(name.value)",
    "upper(name.value)",
    'concat(lower(replace(name.value, " ", ".")), "@x.io")',
    'replace(name.value, "o", "\\\\1")',
    'lookup(kind, {"biz": "business", "it\'s": "quoted"}, "other")',
    'lookup(kind, {"biz": "business"}, null)',
    'concat(lookup(kind, {"biz": "b"}, "o"), upper(name.value))',
    'concat("a", "b")',
    "kind"
  ].freeze

  DERIVE_RECORDS = [
    { "name" => { "value" => "Chris Young" }, "kind" => "biz" },
    { "name" => { "value" => "" }, "kind" => "it's" },
    { "name" => { "value" => "\u00C0\u00C9\u00CE stra\u00DFe" }, "kind" => "BIZ" },
    { "name" => { "value" => "back\\slash \"quoted\"" }, "kind" => "" },
    { "name" => { "value" => 42 }, "kind" => 7 },
    { "name" => { "value" => nil } },
    { "name" => "plain", "kind" => { "label" => "biz" } },
    {}
  ].freeze

  before(:all) do
    skip "no local Postgres" unless PostgresProbe.available?
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DERIVE_DB}")
    admin.exec("CREATE DATABASE #{DERIVE_DB}")
    admin.close
    @db = PG.connect(dbname: DERIVE_DB)
    Hecks::Adapters::PostgresEra::Lineage::TransformSql::ALL.each { |sql| @db.exec(sql) }
  end

  after(:all) do
    @db&.close
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DERIVE_DB}")
    admin.close
  end

  def declared_for(expression)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks.data_translation("Directory", from: "aaaaaa", to: "bbbbbb") do
        aggregate("Member") { derive "out.value", as: expression }
      end
    end
    registry.translations.first.for_aggregate("Member")
  end

  def in_process(declared, record)
    state = record.transform_keys(&:to_sym)
    entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "m1", state: state, mirrors: nil)
    JSON.parse(JSON.generate(Hecks::Ports::Persistence::Lineage.from_declared(declared, "Member").translate(entry).state))
  end

  def in_postgres(declared, record)
    sql = Hecks::Translation::RuleCompiler.compile_rules(declared)
    row = @db.exec_params("SELECT #{sql} AS state FROM (SELECT $1::jsonb AS state) t", [JSON.generate(record)])
    JSON.parse(row[0]["state"])
  end

  DERIVE_EXPRESSIONS.each do |expression|
    it "agrees on #{expression}" do
      declared = declared_for(expression)
      answers = DERIVE_RECORDS.map { |record| [in_process(declared, record), in_postgres(declared, record)] }
      expect(answers.map(&:first)).to eq(answers.map(&:last))
    end
  end

  def rekeyed_for(expression)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks.data_translation("Directory", from: "aaaaaa", to: "bbbbbb") do
        aggregate("Member") do
          derive "out.value", as: expression
          rekey_to "out.value"
        end
      end
    end
    registry.translations.first.for_aggregate("Member")
  end

  def id_in_process(declared, record)
    entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "old", state: record.transform_keys(&:to_sym),
                                                 mirrors: nil)
    Hecks::Ports::Persistence::Lineage.from_declared(declared, "Member").translate(entry).id
  end

  def id_in_postgres(declared, record)
    sql = Hecks::Translation::RuleCompiler.compile_id_expression(declared)
    @db.exec_params("SELECT #{sql} AS id FROM (SELECT 'old'::text AS aggregate_id, $1::jsonb AS state) t",
                    [JSON.generate(record)])[0]["id"]
  end

  DERIVE_EXPRESSIONS.each do |expression|
    it "agrees on the id rekey_to gives from #{expression}" do
      declared = rekeyed_for(expression)
      ids = DERIVE_RECORDS.map { |record| [id_in_process(declared, record), id_in_postgres(declared, record)] }
      expect(ids.map(&:first)).to eq(ids.map(&:last))
    end
  end
end
