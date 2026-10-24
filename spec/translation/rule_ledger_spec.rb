require "spec_helper"
require "hecks/grammar"
require "hecks/ports/persistence/plugins/era/translation/rule_compiler"

# The translation execution ledger (lib/hecks/grammar/translation_rules.json), replayed through the
# translation chapter: every rule kind executes in postgres, sqlite and in_process, and the rule
# compiler's Postgres SQL is the ledger's templates filled, byte for byte what it compiled before.
RSpec.describe "the translation execution ledger" do
  TARGETS = %w[postgres sqlite in_process].freeze

  def self.declared_kinds
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/grammar/translation.bluebook"))
    end
    registry.bluebook("Translation").aggregate("Rule").value_object("Kind").members.map { |row| row.to_h.values.first }
  end

  KINDS = declared_kinds.freeze

  it "admits every declared rule kind, each executing in every target", :aggregate_failures do
    TARGETS.each do |target|
      expect(Hecks::Grammar.rule_executions(target).keys).to match_array(KINDS), target
    end
  end

  it "gives the compiler a Postgres template for every kind it compiles" do
    compiled = %w[derive rename move convert drop backfill rekey_to]
    expect(Hecks::Translation::RuleCompiler.postgres_forms.keys).to include(*compiled)
  end

  def declared
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks.data_translation("Directory", from: "aaaaaa", to: "bbbbbb", &edge) }
    registry.translations.first.for_aggregate("Member")
  end

  def edge
    rules = method(:every_rule)
    proc { aggregate("Member") { rules.call(self) } }
  end

  def every_rule(rules)
    rules.derive "handle.value", as: "lower(name)"
    rules.rename :cost, to: :amount
    rules.move "address.city", to: "location.city"
    rules.convert "tier", to: "level", values: { "gold" => "high", "it's" => "quoted" }
    rules.drop "legacy.flag"
    rules.backfill "status", default: "open"
    rules.rekey_to "handle.value"
  end

  def lowered_name
    "translate((CASE WHEN jsonb_typeof(state #> ARRAY['name']::text[]) = 'string' THEN state #>> ARRAY['name']::text[] " \
      "END), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'::text, 'abcdefghijklmnopqrstuvwxyz'::text)"
  end

  def derived
    "(SELECT CASE WHEN __d IS NULL THEN __s ELSE hecks_tr_insert(__s, ARRAY['handle', 'value']::text[], " \
      "to_jsonb(__d), 'derive handle.value') END FROM (SELECT (state) AS __s) __outer, LATERAL (SELECT " \
      "#{lowered_name} AS __d) __derived)"
  end

  def moved
    "hecks_tr_move(hecks_tr_rename(#{derived}, 'cost', 'amount'), ARRAY['address', 'city']::text[], " \
      "ARRAY['location', 'city']::text[], 'move address.city to: location.city')"
  end

  def converted
    "hecks_tr_convert(#{moved}, ARRAY['tier']::text[], ARRAY['level']::text[], " \
      "'[[\"gold\",\"high\"],[\"it''s\",\"quoted\"]]'::jsonb, 'tier', 'convert tier to: level')"
  end

  def expected_state
    "(SELECT CASE WHEN (hecks_tr_extract(__s, ARRAY['status']::text[])).present THEN __s ELSE hecks_tr_insert(__s, " \
      "ARRAY['status']::text[], '\"open\"'::jsonb, 'backfill status') END FROM (SELECT " \
      "(hecks_tr_drop(#{converted}, ARRAY['legacy', 'flag']::text[])) AS __s) __outer)"
  end

  it "compiles every rule kind to the SQL the hand-built compiler wrote" do
    expect(Hecks::Translation::RuleCompiler.compile_rules(declared)).to eq(expected_state)
  end

  it "compiles a rekey to the id expression the hand-built compiler wrote" do
    expect(Hecks::Translation::RuleCompiler.compile_id_expression(declared)).to eq("COALESCE(#{lowered_name}, aggregate_id)")
  end
end
