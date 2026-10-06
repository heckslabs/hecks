require "spec_helper"
require "hecks/fuzzing"

# `Properties.read_model_names_resolve_uniquely` and `.read_model_heads_compose_from_references`.
# A real banking replay passes both; the failing cases doctor a recorded ask or a bluebook's names,
# since a runtime composing the wrong rows cannot be provoked on demand.
RSpec.describe "Hecks::Fuzzing::Properties read-model properties", :aggregate_failures do
  def banking_path = File.join(InMemoryDomain::ROOT, "examples/banking")

  def names(history) = Hecks::Fuzzing::Properties.read_model_names_resolve_uniquely(history)

  def heads(history) = Hecks::Fuzzing::Properties.read_model_heads_compose_from_references(history)

  def register_step(reference)
    { "verb" => "Banking::Customer.Register",
      "args" => { "reference" => { "value" => reference },
                  "name"      => { "given" => "Ada", "family" => "Lovelace" },
                  "email"     => { "address" => "ada@example.com" } } }
  end

  def open_step(number, reference)
    { "verb" => "Banking::Account.Open",
      "args" => { "number" => { "value" => number }, "kind" => { "name" => "current" },
                  "daily_limit" => { "cents" => 50_000 }, "customer" => reference } }
  end

  def portfolio_history
    reference = "RMP-#{rand(1_000_000_000)}"
    ask = { "query" => "Banking.customer_portfolio", "args" => { "customer" => reference } }
    steps = [register_step(reference), open_step("#{reference}-A", reference), open_step("#{reference}-B", reference), ask]
    Hecks::Fuzzing::Replay.call(banking_path, steps).tap { |history| expect(history[:refusals]).to eq([]) }
  end

  # The same history with its one portfolio ask's answer edited.
  def edited(history)
    ask = history[:queries].last
    answer = yield(ask[:rows].first)
    history.merge(queries: [ask.merge(rows: [answer])])
  end

  def accounts_of(answer) = answer[:accounts]

  # A bluebook stand-in resolving read models by either spelling, as the real chapter does.
  def bluebook_of(*models)
    Struct.new(:name, :read_models) do
      def read_model(spelling) = read_models.find { |held| [held.name, held.query_name].include?(spelling) }
    end.new("Banking", models)
  end

  def model_named(name, query_name) = Struct.new(:name, :query_name).new(name, query_name)

  describe "read_model_names_resolve_uniquely" do
    it "passes the banking read models" do
      expect(names(bluebooks: Hecks::Fuzzing::Replay.call(banking_path, [])[:bluebooks])).to be(true)
    end

    it "names a read model whose query_name drifts from its snake-cased name" do
      bluebook = bluebook_of(model_named("CustomerPortfolio", "portfolio"))

      expect(names(bluebooks: { "Banking" => bluebook })).to be_a(String).and include("CustomerPortfolio", "customer_portfolio")
    end

    it "names two read models sharing one query name" do
      bluebook = bluebook_of(model_named("Ab", "ab"), model_named("AB", "ab"))

      expect(names(bluebooks: { "Banking" => bluebook })).to be_a(String).and include("one query name")
    end
  end

  describe "read_model_heads_compose_from_references" do
    it "passes a real multi-head ask: the root and the accounts that reference it" do
      history = portfolio_history

      expect(heads(history)).to be(true)
      expect(accounts_of(history[:queries].last[:rows].first).size).to eq(2)
    end

    it "passes a history with no read-model asks" do
      expect(heads(bluebooks: Hecks::Fuzzing::Replay.call(banking_path, [])[:bluebooks], queries: [])).to be(true)
    end

    it "names a many-side head answered with a record that does not reference the root" do
      doctored = edited(portfolio_history) do |answer|
        answer.merge(accounts: accounts_of(answer) + [accounts_of(answer).first.merge(id: "STRANGER")])
      end

      expect(heads(doctored)).to be_a(String).and include("Banking.customer_portfolio head accounts", "STRANGER")
    end

    it "names a many-side head missing a record that references the root" do
      doctored = edited(portfolio_history) { |answer| answer.merge(accounts: accounts_of(answer).first(1)) }

      expect(heads(doctored)).to be_a(String).and include("head accounts")
    end

    it "names an answer carrying a head the read model never declared" do
      doctored = edited(portfolio_history) { |answer| answer.merge(phantoms: []) }

      expect(heads(doctored)).to be_a(String).and include("phantoms")
    end

    it "draws no conclusion from an ask that was refused" do
      history = portfolio_history
      refused = history[:queries].last.merge(error: "no such record", rows: nil)

      expect(heads(history.merge(queries: [refused]))).to be(true)
    end
  end
end
