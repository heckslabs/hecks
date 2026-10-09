require "spec_helper"
require "tempfile"

# model_check's three words about `ask` (ADR 0100): an ask no declared ask answers is an error, a
# declared ask nothing asks is a warning, and a trigger that names a port operation is a warning
# so the waves of migration can be counted.
RSpec.describe "model_check over ask" do
  ASK_FIXTURES = File.join(InMemoryDomain::ROOT, "spec/fixtures/ask").freeze
  ERRAND_DIR = File.join(InMemoryDomain::ROOT, "spec/corpus/asks/domain/bluebook").freeze

  def errand_with(hecksagon, bluebook: File.join(ERRAND_DIR, "errand.bluebook"))
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, bluebook, hecksagon].each { |f| Kernel.load(f) }
    end
    registry.bluebook("Errand")
  end

  # The Errand chapter with RunWhenRequested still naming its port, as a trigger.
  def triggering_bluebook
    source = File.read(File.join(ERRAND_DIR, "errand.bluebook"))
    Tempfile.new(["errand_triggered", ".bluebook"]).tap do |file|
      file.write(source.sub("ask :run, with:", "trigger Job::Worker::Run, with:"))
      file.flush
    end
  end

  def findings(hecksagon, **rest)
    Hecks::Bluebook::ModelCheck.call(errand_with(hecksagon, **rest)).map { |f| [f.kind, f.severity, f.subject] }
  end

  it "reports no error for the corpus domain, and the ask_via loser as the one unused ask" do
    expect(findings(File.join(ERRAND_DIR, "errand.hecksagon")).select { |f| f[1] == :error || f[0] == :unused_ask })
      .to eq([[:unused_ask, :warning, "Job.Worker.Audit"]])
  end

  it "reports an ask no declared ask answers as an error" do
    expect(findings(File.join(ASK_FIXTURES, "errand_without_run.hecksagon")))
      .to include([:unresolved_ask, :error, "RunWhenRequested"])
  end

  it "reports a declared ask no policy uses as a warning" do
    expect(findings(File.join(ASK_FIXTURES, "errand_with_spare_ask.hecksagon")))
      .to include([:unused_ask, :warning, "Job.Spare.Spare"])
  end

  it "reports a port-naming trigger as a warning" do
    triggered = findings(File.join(ERRAND_DIR, "errand.hecksagon"), bluebook: triggering_bluebook.path)

    expect(triggered).to include([:port_trigger, :warning, "RunWhenRequested"])
  end
end
