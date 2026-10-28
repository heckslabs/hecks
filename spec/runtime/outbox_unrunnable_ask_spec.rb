require "spec_helper"

# A redriven outbox row whose consumer is a policy `ask` is run only by a process that has the
# adapter bound to the ask's port. A process without it leaves the row pending (and says so once),
# instead of claiming it and settling it as a refusal nobody reads. Runs in Memory.
RSpec.describe "redriving an outbox row whose ask this process cannot run" do
  ERRAND_DOMAIN = File.join(InMemoryDomain::ROOT, "spec/corpus/asks/domain/bluebook").freeze
  ASK_CONSUMERS = %w[policy:Errand::RunWhenRequested policy:Errand::AuditWhenRequested].freeze

  module Hecks
    module Adapters
      # Answers the Errand ask the specs below bind to the Worker port.
      class ErrandWorker
        def run(ref:, **) = { ref: ref }
      end

      # Answers the Errand ask the specs below bind to the Inspector port.
      class ErrandInspector
        def audit(ref:, **) = { ref: ref }
      end
    end
  end

  def booted_errand(with_adapter:)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, *%w[errand.bluebook errand.hecksagon].map { |file| File.join(ERRAND_DOMAIN, file) }]
        .each { |file| Kernel.load(file) }
      bind_answerer if with_adapter
    end
    registry.verify!
    registry
  end

  def bind_answerer
    Hecks.adapter("ErrandWorker") { port "Worker" }
    Hecks.adapter("ErrandInspector") { port "Inspector" }
  end

  # The ask rows a crash would leave behind: requested, then every ask row put back to pending.
  def with_pending_asks(registry)
    dispatcher = Hecks::Runtime::Dispatcher.new(registry)
    dispatcher.dispatch_flat("Errand::Job.Request", ref: { value: "J1" })
    repository = registry.repository("Errand", registry.bluebook("Errand").aggregate("Job"))
    dispatcher.outbox.rows.select { |row| ASK_CONSUMERS.include?(row.consumer) }
              .each { |row| repository.outbox_settle(row.id, status: "pending") }
    registry.event_log.clear
    dispatcher
  end

  def ask_rows(dispatcher) = dispatcher.outbox.rows.select { |row| ASK_CONSUMERS.include?(row.consumer) }

  context "when no adapter is bound for the ask's port" do
    let(:registry)   { booted_errand(with_adapter: false) }
    let(:dispatcher) { with_pending_asks(registry) }

    def redrive_quietly = expect { dispatcher.outbox.redrive! }.to output(/left pending/).to_stderr

    it "leaves the ask rows pending, unclaimed", :aggregate_failures do
      redrive_quietly

      expect(ask_rows(dispatcher).map(&:status)).to eq(%w[pending pending])
      expect(ask_rows(dispatcher).map(&:attempts).uniq).to eq([1])
    end

    it "emits no answer and no refusal for the ask" do
      redrive_quietly

      expect(registry.event_log.map(&:name)).to be_empty
    end

    it "logs each withheld row, with the plain reason", :aggregate_failures do
      redrive_quietly
      withheld = dispatcher.outbox.log.select { |entry| entry[:withheld] }

      expect(withheld.size).to eq(2)
      expect(withheld.first[:reason]).to eq("no adapter bound for Worker.Run in this process")
    end
  end

  context "when the process has the adapter" do
    let(:registry)   { booted_errand(with_adapter: true) }
    let(:dispatcher) { with_pending_asks(registry) }

    it "still claims, runs and settles the ask rows" do
      dispatcher.outbox.redrive!

      expect(ask_rows(dispatcher).map(&:status)).to eq(%w[delivered delivered])
    end

    it "answers the ask" do
      dispatcher.outbox.redrive!

      expect(registry.event_log.map(&:name)).to include("JobRan")
    end
  end
end
