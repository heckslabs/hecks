require "spec_helper"

# The limits and word lists the language puts on a declaration are declared in vocabulary.bluebook
# (LanguageLimit, NeedableFact, CommandAudience, OutboxStatus). The Ruby reads them from the generated
# table; Rust cannot yet, so each Rust constant is held equal to its declaration here, and a number
# changed in one place fails until the other follows.
RSpec.describe "The language limits both engines enforce" do
  def read(path) = File.read(File.expand_path("../#{path}", __dir__))

  def limit(name) = Hecks::Limit.of("LanguageLimit", name)

  def words(table) = Hecks::Vocabulary.fetch(table)

  def rust_number(path, constant) = read(path)[/const #{constant}: usize = (\d+);/, 1].to_i

  def rust_words(path, constant) = read(path)[/const #{constant}: &\[&str\] = &\[([^\]]*)\]/, 1].scan(/"(\w+)"/).flatten

  describe "Ruby" do
    it "nests reactions as deep as the declaration says" do
      expect(Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH).to eq(limit("reaction_depth"))
    end

    it "follows references as many hops as the declaration says" do
      expect(Hecks::Runtime::CommandRules::References.const_get(:DEREFERENCE_DEPTH)).to eq(limit("reference_hops"))
    end

    it "stops hop chains where the declaration says" do
      expect(Hecks::QuerySpecification::HopPath::MAX_HOPS).to eq(limit("chain_hops"))
    end

    it "calls a claim stalled after the declared seconds" do
      expect(Hecks::Runtime::Outbox::STALLED_AFTER).to eq(limit("outbox_stalled_after_seconds"))
    end

    it "admits the outbox statuses the declaration lists" do
      expect(Hecks::Runtime::Outbox::STATUSES).to eq(words("OutboxStatus"))
    end

    it "admits the needable facts the declaration lists" do
      expect(Hecks::Bluebook::DSL::NeedWord::NEEDABLE_FACTS.map(&:to_s)).to eq(words("NeedableFact"))
    end

    it "admits the audiences the declaration lists" do
      expect(Hecks::Bluebook::DSL::AudienceWord::AUDIENCES).to eq(words("CommandAudience"))
    end
  end

  describe "Rust" do
    it "nests reactions as deep as the declaration says" do
      expect(rust_number("rust/src/kernel/orchestrate.rs", "MAX_REACTION_DEPTH")).to eq(limit("reaction_depth"))
    end

    it "follows references as many hops as the declaration says" do
      expect(rust_number("rust/src/kernel/reference_lookup.rs", "DEREFERENCE_DEPTH")).to eq(limit("reference_hops"))
    end

    it "stops hop chains where the declaration says" do
      expect(rust_number("rust/codegen/src/queries.rs", "HOP_CHAIN_LIMIT")).to eq(limit("chain_hops"))
    end

    it "stops projection chains where the declaration says" do
      expect(rust_number("rust/codegen/src/types.rs", "PROJECTION_CHAIN_LIMIT")).to eq(limit("chain_hops"))
    end

    it "admits the needable facts the declaration lists" do
      expect(rust_words("rust/parser/src/parse/needs.rs", "NEEDABLE_FACTS")).to eq(words("NeedableFact"))
    end

    it "admits the audiences the declaration lists" do
      expect(rust_words("rust/parser/src/parse/audience.rs", "AUDIENCES")).to eq(words("CommandAudience"))
    end
  end
end
