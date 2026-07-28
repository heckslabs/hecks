# THE NAMING CONTRACT — one rule, and the cases that pin it.
#
# `Naming.snake` decides more than it looks like it decides. The same rule
# names the .heki file an aggregate is stored in, the SQL table it maps to, the
# Ruby method a command becomes, and the key a `reference_to` lets a caller say.
# Those four spellings have to be the SAME WORD or the domain comes apart at
# runtime — a record written to one path and looked for at another.
#
# So the rule is stated once, here, and every case below is a case some other
# file would otherwise have had to guess at. THE ACRONYM CASES ARE THE POINT.
# A naive "underscore before every capital" rule agrees with this one on
# `LedgerEntry` and disagrees on `ATMCard` — which is exactly why three call
# sites once open-coded it, all three got the easy cases right, and all three
# were wrong about the same hard one.
#
# THIS SPEC IS A CROSS-RUNTIME CONTRACT. rust/src/naming.rs mirrors it
# case-for-case ; if you change an expectation here, change it there in the
# same commit or bin/parity will report a SPLIT.
require "hecksagain"

RSpec.describe Hecksagain::Naming do
  describe ".snake" do
    it "lowercases a single word" do
      expect(described_class.snake("Pizza")).to eq("pizza")
    end

    it "breaks on the lowercase-to-uppercase boundary" do
      expect(described_class.snake("LedgerEntry")).to eq("ledger_entry")
      expect(described_class.snake("AddTopping")).to eq("add_topping")
      expect(described_class.snake("CreatePizza")).to eq("create_pizza")
    end

    # THE HARD CASES. A run of capitals is ONE word, and the break belongs
    # before the capital that starts the NEXT word — not between every pair.
    it "keeps a leading acronym whole" do
      expect(described_class.snake("ATMCard")).to eq("atm_card")
      expect(described_class.snake("HTTPGateway")).to eq("http_gateway")
      expect(described_class.snake("APIEndpoint")).to eq("api_endpoint")
      expect(described_class.snake("DNAProfile")).to eq("dna_profile")
    end

    it "keeps a trailing acronym whole" do
      expect(described_class.snake("DigitalID")).to eq("digital_id")
      expect(described_class.snake("CustomerAPI")).to eq("customer_api")
    end

    it "treats a digit as part of the word it trails" do
      expect(described_class.snake("Base64Encoder")).to eq("base64_encoder")
    end

    it "leaves an already-snake name alone" do
      expect(described_class.snake("ledger_entry")).to eq("ledger_entry")
      expect(described_class.snake("pizza")).to eq("pizza")
    end

    it "accepts a symbol or a class-like object, not only a string" do
      expect(described_class.snake(:AddTopping)).to eq("add_topping")
    end
  end

  describe ".demodulise" do
    it "drops the domain prefix" do
      expect(described_class.demodulise("Pizzas::Pizza")).to eq("Pizza")
      expect(described_class.demodulise("Banking::ATMCard")).to eq("ATMCard")
    end

    it "leaves a bare name alone" do
      expect(described_class.demodulise("Pizza")).to eq("Pizza")
    end

    it "keeps only the LAST segment, however deep" do
      expect(described_class.demodulise("A::B::C")).to eq("C")
    end
  end

  # THE KEY AN AGGREGATE IS ADDRESSED BY FROM OUTSIDE ITSELF. One idea that
  # wore three names before it wore this one — `reference_key` on the command
  # path, `parent_key` on the query path, `own_key` in the saga.
  describe ".reference_key" do
    it "is the snake of the bare name, as a symbol" do
      expect(described_class.reference_key("Transfer")).to eq(:transfer)
      expect(described_class.reference_key("LedgerEntry")).to eq(:ledger_entry)
    end

    it "demodulises before snaking" do
      expect(described_class.reference_key("Banking::Transfer")).to eq(:transfer)
    end

    # The case that proves the three open-coded copies were wrong together:
    # storage_name said "atm_card" while the reference key said "atmcard", so
    # a correctly-spelled command could not find the aggregate it named.
    it "agrees with the storage spelling on an acronym" do
      expect(described_class.reference_key("Banking::ATMCard")).to eq(:atm_card)
      expect(described_class.reference_key("ATMCard").to_s)
        .to eq(described_class.snake("ATMCard"))
    end
  end

  # TAKING A NAME APART. One grammar — `Qualifier.name` — carries an entity
  # command, an entity query, and a qualified subscription. It was read in
  # four places before it was read here.
  describe ".split_dotted" do
    it "splits a dotted name into its two parts" do
      expect(described_class.split_dotted("Account.Opened")).to eq(["Account", "Opened"])
      expect(described_class.split_dotted("Line.overdue")).to eq(["Line", "overdue"])
    end

    # A BARE NAME IS THE FIRST PART. An entity path with no dot names an
    # entity and no member — which is why the split reports what is written
    # and leaves the reading to `qualifier`.
    it "reads a bare name as the first part" do
      expect(described_class.split_dotted("Opened")).to eq(["Opened"])
      expect(described_class.split_dotted("Opened").last).to eq("Opened")
    end

    it "splits on the FIRST dot only" do
      expect(described_class.split_dotted("A.B.C")).to eq(["A", "B.C"])
    end
  end

  describe ".qualifier" do
    it "names the qualifier of a dotted name" do
      expect(described_class.qualifier("Account.Opened")).to eq("Account")
    end

    it "is nil for a bare name" do
      expect(described_class.qualifier("Opened")).to be_nil
    end
  end

  describe ".split_verb" do
    it "reads a fully-qualified verb into its three parts" do
      expect(described_class.split_verb("Pizzas::Pizza.Purchase"))
        .to eq(["Pizzas", "Pizza", "Purchase"])
    end

    # The REFUSAL belongs to the caller — Naming reports the shape and says
    # nothing about what the caller wanted.
    it "answers nil when the verb is not fully qualified" do
      expect(described_class.split_verb("Pizza.Purchase")).to be_nil
      expect(described_class.split_verb("Pizzas::Pizza")).to be_nil
      expect(described_class.split_verb("")).to be_nil
    end
  end
end
