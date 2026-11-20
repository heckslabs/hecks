require "hecks"
require "hecks/bench/workload"
require "hecks/rust_build/kernel_engine"
require "hecks/fuzzing/isolated_boot"
require_relative "support/kernel_twin"

# The dispatcher surface past slice 1, twinned: banking's bench cycle, `dry_run?` refusals raised
# as the same Ruby class and message, a `to:`-addressed dispatch, and the store a refused dispatch
# leaves. A dispatch refusal is compared by message alone: the kernel's dispatch answer names no
# refusal class yet, so the kernel engine raises `KernelDispatcher::Refused`. A refusal's
# `to_h` (attribute, path, rule, detail) is not compared.
RSpec.describe Hecks::Runtime::KernelDispatcher, :io do
  include KernelTwin

  let(:pizzas_dir) { File.expand_path("../examples/pizzas", __dir__) }
  let(:create) { Hecks::Bench::Workload.create_pizza("pizza-0") }

  def created(dispatcher)
    dispatcher.dispatch_flat(create.verb, create.ruby_args).events.first.id
  end

  def twin(dir = pizzas_dir, &) = %i[ruby kernel].map { |engine| on_engine(dir, engine, &) }

  # Banking persists to Heki, so both engines run a Memory copy of it.
  describe "the banking cycle" do
    let(:workload) { Hecks::Bench::Workload.banking }

    def run_banking(dispatcher)
      (workload.setup + workload.cycle(0)).each { |step| dispatcher.dispatch_flat(step.verb, step.ruby_args) }
      canonical(dispatcher.events)
    end

    it "announces the same events through both engines" do
      ruby, kernel = %i[ruby kernel].map { |engine| on_memory_copy(workload.domain_path, engine) { |d| run_banking(d) } }
      expect(kernel).to eq(ruby).and(satisfy { |events| !events.empty? })
    end
  end

  describe "dry_run?" do
    def purchase_would_take?(dispatcher, name)
      dispatcher.dry_run?("Pizzas::Order.Purchase", name: name, customer_name: { "value" => "Chris" },
                                                     amount: { "cents" => 1200 })
    end

    it "answers true through both engines" do
      answers = twin { |d| d.dry_run?(create.verb, **create.ruby_args) }
      expect(answers).to eq([true, true])
    end

    it "raises GivenNotMet with the same message through both engines" do
      ruby, kernel = twin { |d| created(d) && outcome { purchase_would_take?(d, "pizza-0") } }
      expect(kernel).to eq(ruby)
    end

    it "raises the same class and message for an unknown argument" do
      ruby, kernel = twin { |d| outcome { d.dry_run?(create.verb, **create.ruby_args, flavour: "x") } }
      expect(kernel).to eq(ruby)
    end
  end

  describe "a dispatch addressed with to:" do
    let(:topping) { { topping: { "value" => "Basil" }, amount: { "value" => 3 } } }

    it "announces the same events through both engines" do
      ruby, kernel = twin do |d|
        d.dispatch("Pizzas::Order.AddTopping", to: created(d), with: topping)
        canonical(d.events)
      end
      expect(kernel).to eq(ruby)
    end
  end

  describe "a refused dispatch" do
    let(:purchase) { Hecks::Bench::Workload.purchase("pizza-0") }

    it "is refused with the same message through both engines" do
      ruby, kernel = twin { |d| created(d) && refusal_text { d.dispatch_flat(purchase.verb, purchase.ruby_args) } }
      expect(kernel).to eq(ruby)
    end

    def instances_around_refusal(client)
      dispatcher = described_class.new(client)
      created(dispatcher)
      before = client.call("instances" => true)
      refusal_text { dispatcher.dispatch_flat(purchase.verb, purchase.ruby_args) }
      [before, client.call("instances" => true)]
    end

    it "leaves the kernel's store as it was" do
      client = Hecks::RustBuild::KernelClient.open(Hecks::RustBuild::KernelEngine.binary_for("pizzas"))
      before, after = instances_around_refusal(client)
      expect(after).to eq(before)
    ensure
      client&.close
    end
  end

  # The kernel marks no saga leg stalled, and a fresh boot holds no stalled leg in process either.
  describe "redrive_sagas!" do
    it "finds no stalled saga leg on a fresh Memory boot in process" do
      stalled = on_engine(pizzas_dir, :ruby) { |d| d.registry.saga_instances.values.flat_map(&:values) }
      expect(stalled.select { |instance| instance[:stalled] }).to be_empty
    end
  end

  describe "the corpus domains" do
    def corpus_steps(name)
      JSON.parse(File.read(File.expand_path("corpus/#{name}.json", __dir__))).fetch("steps")
          .select { |step| step.key?("verb") && (step.keys - %w[verb args]).empty? }
    end

    def run_corpus(dispatcher, steps)
      texts = steps.map { |step| refusal_text { dispatcher.dispatch_flat(step["verb"], step["args"].transform_keys(&:to_sym)) } }
      [canonical(dispatcher.events), texts]
    end

    %w[chess roster].each do |name|
      it "runs #{name}'s corpus steps to the same events and refusals through both engines" do
        dir = File.expand_path("../examples/#{name}", __dir__)
        ruby, kernel = twin(dir) { |dispatcher| run_corpus(dispatcher, corpus_steps(name)) }
        expect(kernel).to eq(ruby)
      end
    end
  end
end
