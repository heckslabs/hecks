require "spec_helper"
require "hecks/fuzzing/mutation"

# Mutation testing of a domain's own checks. The operator and report examples are pure; the run
# examples boot the pizzas example, so they are small and seeded.
RSpec.describe Hecks::Fuzzing::Mutation, :aggregate_failures do
  MUTATION_SPEC_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Tiny" do
      aggregate "Order" do
        value_object "Price" do
          attribute :cents, Integer, pattern: '[0-9]+'
          invariant("a price is never negative") { cents >= 0 }
        end

        value_object "Size" do
          attribute :value, String, one_of: ["small", "large"]
        end

        query "Cheap" do
          where(:"price.cents" => { lt: 500 })
        end

        lifecycle :status, default: "open" do
          transition "Close" => "closed", from: "open"
          transition "Reopen" => "open", from: "closed"
        end

        command "Place", from: "open" do
          role "Clerk"
          goal "place an order"

          given("at most 10") { items.size < 10 }
          sets :name
          emits Placed
        end

        command "Cancel" do
          role "Clerk"
          goal "cancel"

          emits Cancelled
        end
      end

      policy "Notify" do
        on Order::Placed
        trigger Order::Cancel
      end

      process_manager "Fulfilment" do
        correlates_by :id
        starts_on Order::Placed
        ends_on Order::Cancelled

        transition Order::Placed => "placed", from: "start" do
          dispatch Order::Cancel, with: { id: :id }
        end
      end
    end
  BLUEBOOK

  def sites = Hecks::Fuzzing::Mutation::Operators.sites("tiny.bluebook" => MUTATION_SPEC_SOURCE)

  def mutate(operator)
    site = sites.find { |candidate| candidate.operator == operator }
    site.apply(MUTATION_SPEC_SOURCE.lines).join
  end

  describe Hecks::Fuzzing::Mutation::Operators do
    it "finds a site for every operator in the catalog" do
      expect(sites.map(&:operator).uniq).to match_array(described_class::CATALOG.keys)
    end

    it "names a site by operator and place" do
      site = sites.find { |candidate| candidate.operator == :drop_given }

      expect(site.id).to eq("drop_given@tiny.bluebook:#{MUTATION_SPEC_SOURCE.lines.index { |line| line.include?("given(") } + 1}")
    end

    it "removes a given, an invariant and a sets line outright" do
      expect(mutate(:drop_given)).not_to include("at most 10")
      expect(mutate(:drop_invariant)).not_to include("never negative")
      expect(mutate(:drop_sets)).not_to include("sets :name")
    end

    it "moves a comparison one step and swaps a query bound" do
      expect(mutate(:flip_comparison)).to include("cents > 0").or include("size <= 10")
      expect(mutate(:flip_query_bound)).to include("gt: 500")
    end

    it "loosens a pattern and a lifecycle guard" do
      expect(mutate(:drop_pattern)).to include("attribute :cents, Integer\n")
      guards = ->(text) { text.scan('from: "open"').size }

      expect(guards.call(mutate(:drop_from_guard))).to be < guards.call(MUTATION_SPEC_SOURCE)
    end

    it "points a transition at another state" do
      expect(mutate(:retarget_transition)).to match(/transition "Close" => "open"|transition "Reopen" => "closed"/)
    end

    it "removes the whole policy block and the whole saga transition" do
      expect(mutate(:drop_policy)).not_to include("Notify")
      saga = mutate(:drop_saga_transition)
      expect(saga).not_to include("dispatch Order::Cancel")
      expect(saga).to include("process_manager \"Fulfilment\"")
    end

    it "drops only the dispatch a handler makes" do
      expect(mutate(:drop_saga_dispatch)).to include('transition Order::Placed => "placed"')
      expect(mutate(:drop_saga_dispatch)).not_to include("dispatch Order::Cancel")
    end

    it "swaps an emitted event for another of the file" do
      expect(mutate(:swap_emits)).to match(/emits Cancelled.*emits Cancelled|emits Placed.*emits Placed/m)
    end

    it "finds nothing to change in a file with no rules" do
      expect(described_class.sites("empty.bluebook" => "Hecks.bluebook \"E\" do\nend\n")).to be_empty
    end
  end

  describe Hecks::Fuzzing::Mutation::Report do
    def outcome(status) = Hecks::Fuzzing::Mutation::Outcome.new(site: sites.first, status: status, by: nil)

    def report(*statuses)
      facts = described_class::Facts.new("tiny", 1, 9, 3, true)
      described_class.new(facts, statuses.map { |status| outcome(status) })
    end

    it "scores killed over killed plus survived, leaving unreached and invalid out" do
      report = report(:killed, :killed, :killed, :survived, :unreached, :invalid)

      expect(report.score).to eq(0.75)
      expect(report.to_s).to include("score 75%").and include("SURVIVED").and include("UNREACHED")
    end

    it "has no score when nothing changed behavior, and then passes any minimum" do
      report = report(:unreached, :invalid)

      expect(report.score).to be_nil
      expect(report.passes?(1.0)).to be(true)
    end

    it "fails a minimum the score does not reach" do
      expect(report(:killed, :survived).passes?(0.75)).to be(false)
      expect(report(:killed, :survived).passes?(0.5)).to be(true)
    end
  end

  describe Hecks::Fuzzing::Mutation::Run do
    let(:pizzas) { File.join(InMemoryDomain::ROOT, "examples/pizzas") }
    let(:options) { { seed: 7, budget: 4, seeds: 1, steps: 12, operators: %i[drop_given drop_one_of drop_policy] } }

    def summary(report) = report.verdicts.map { |outcome| [outcome.site.id, outcome.status] }

    it "tries a seeded, repeatable choice of mutants" do
      first = described_class.call(pizzas, **options)

      expect(summary(first)).to eq(summary(described_class.call(pizzas, **options)))
      expect(first.verdicts.size).to be <= 4
    end

    it "files every mutant under one of the four verdicts" do
      statuses = described_class.call(pizzas, **options).verdicts.map(&:status)

      expect(statuses - %i[killed survived unreached invalid]).to be_empty
    end

    it "kills a mutant the domain's own behaviors tests refuse" do
      report = described_class.call(pizzas, **options, operators: [:drop_given])

      expect(report.killed.map(&:by)).to include(a_string_starting_with("behavior:"))
    end

    def mtimes(root)
      Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }.to_h { |path| [path, File.mtime(path)] }
    end

    it "leaves the domain's own files untouched" do
      before = mtimes(pizzas)

      described_class.call(pizzas, **options, budget: 1)

      expect(mtimes(pizzas)).to eq(before)
    end
  end

  describe "the mutate tool" do
    it "refuses a flag it does not know" do
      require "hecks/tools/mutation_run"

      expect { Hecks::Tools::MutationRun.parse(["--bogus"]) }.to raise_error(SystemExit).and output(/unknown argument/).to_stderr
    end

    it "reads the flags it documents" do
      require "hecks/tools/mutation_run"

      options = Hecks::Tools::MutationRun.parse(%w[--seed 5 --budget 9 --operators drop_given,drop_policy --min-score 0.5])

      expect(options).to include(seed: 5, budget: 9, operators: %i[drop_given drop_policy], min_score: 0.5)
    end
  end

  describe "the ProcessPool adapter's probe" do
    require_relative "../../lib/hecks/hecks/adapters/process_pool"

    after { Hecks::Adapters::ProcessPool.starter = nil }

    let(:asked) { [] }

    before do
      done = Hecks::Adapters::ProcessPool::Finished.new("mutation pizzas\n", Struct.new(:success?, :exitstatus).new(true, 0))
      Hecks::Adapters::ProcessPool.starter = ->(command, _env, _chdir) { (asked << command) && done }
    end

    it "runs the mutate tool over the domain with the flags the record holds", :aggregate_failures do
      answer = Hecks::Adapters::ProcessPool.new.probe(domain: { value: "examples/pizzas" }, budget: { value: 4 })

      expect(asked.first[4]).to include('Hecks::Tools.script("mutate", ARGV)')
      expect(asked.first.drop(6)).to eq(%w[examples/pizzas --budget 4])
      expect(answer).to eq(report: { value: "mutation pizzas\n" })
    end
  end
end
