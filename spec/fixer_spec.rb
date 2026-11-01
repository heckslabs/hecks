require "spec_helper"

# The fixer booted beside the QualityControl ledger, in Memory, so the ledger's policies hear the
# fixer's events and the fixer hears the ledger's. Each example boots its own registry.
RSpec.describe "the fixer" do
  def fixer_root = File.join(InMemoryDomain::ROOT, "lib/hecks/fixer")

  def ledger_root = File.join(InMemoryDomain::ROOT, "lib/hecks/quality_control")

  def boot_fixer_beside_ledger
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) { load_ledger_and_fixer }
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # The ledger's bluebook and the fixer's, loaded the way the ledger's own spec loads it.
  def load_ledger_and_fixer
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
     InMemoryDomain::PRISM_ADAPTER, File.join(ledger_root, "quality_control.bluebook"),
     File.join(fixer_root, "fixer.bluebook")].each { |file| Kernel.load(file) }
    Kernel.load(File.join(fixer_root, "fixer.hecksagon"))
  end

  let(:runtime) { boot_fixer_beside_ledger }

  def log_bug(reference = "BUG#1")
    runtime
    target = QualityControl::Target.identify!(reference: { value: "banking" }, path: { value: "examples/banking" })
    sweep = QualityControl::Sweep.open!(target: target.id, reference: { value: "SW-1" },
                                        engineer: { value: "Claude QA" })
    QualityControl::Bug.log!(sweep: sweep.id, reference: { value: reference }, sequence: { value: 1 },
                             title: { value: "a bug" }, demonstration: { value: "rspec x" },
                             symptom: { value: "wrong" }, expectation: { value: "right" },
                             submitter: { value: "Claude QA" })
  end

  def ledger_bug(reference = "BUG#1") = QualityControl::Bug.find(reference)

  def attempt(reference = "BUG#1") = Fixer::Attempt.find(reference)

  def claim(reference = "BUG#1", by: "fixer-one")
    attempt(reference).claim!(reference: { value: reference }, held_by: { value: by }, now: { value: 1_000 })
  end

  # A command the attempt records and never runs. dead-name-check: skip
  REPRO = "exe/hecks widget.make --wait".freeze

  def investigate(reference = "BUG#1", result: "failed", command: REPRO)
    attempt(reference).investigate!(reference: { value: reference }, site: { value: "lib/x.rb" },
                                    cause: { value: "c" }, reproduction: { value: command },
                                    observed: { value: "era resolved nil" }, reproduced: { value: result })
  end

  def fix(reference = "BUG#1", commit = "4f2a19c")
    investigate(reference)
    attempt(reference).fix!(reference: { value: reference }, commit: { value: commit })
  end

  def verify(reference = "BUG#1", commit = "4f2a19c", rerun: REPRO, rerun_result: "passed")
    attempt(reference).verify!(reference: { value: reference }, commit: { value: commit },
                               evidence: { value: "rspec: 1 example, 0 failures" },
                               rerun: { value: rerun }, rerun_result: { value: rerun_result })
  end

  it "opens an attempt when the ledger logs a bug, still unclaimed", :aggregate_failures do
    log_bug

    expect(attempt.status).to eq("logged")
    expect(attempt.held_by.value).to eq("nobody")
  end

  it "leaves a logged bug unclaimed and unfixed on the ledger", :aggregate_failures do
    log_bug

    expect(ledger_bug.status).to eq("logged")
    expect(ledger_bug.held_by.value).to eq("nobody")
  end

  it "refuses a second fixer while the first still holds the attempt" do
    log_bug
    claim(by: "fixer-one")

    expect { claim(by: "fixer-two") }.to raise_error(Hecks::Runtime::GivenNotMet, /not taken from the agent holding it/)
  end

  it "records the claim on the ledger from AttemptClaimed" do
    log_bug
    claim

    expect(ledger_bug.held_by.value).to eq("fixer-one")
  end

  it "records the fixed state on the ledger from FixReady" do
    log_bug
    claim
    fix

    expect(ledger_bug.status).to eq("fixed")
  end

  it "records the verified state on the ledger from FixVerified" do
    log_bug
    claim
    fix
    verify

    expect(ledger_bug.status).to eq("verified")
  end

  describe "the reproduction rule" do
    it "refuses a fix when no reproduction was recorded" do
      log_bug
      claim

      expect { attempt.fix!(reference: { value: "BUG#1" }, commit: { value: "4f2a19c" }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /no failing reproduction recorded: run the real entry point first/)
    end

    it "refuses a fix when the recorded reproduction did not fail" do
      log_bug
      claim
      investigate(result: "passed")

      expect { attempt.fix!(reference: { value: "BUG#1" }, commit: { value: "4f2a19c" }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /no failing reproduction recorded/)
    end

    it "accepts a fix once a failing reproduction is recorded", :aggregate_failures do
      log_bug
      claim
      fix

      expect(attempt.status).to eq("fixed")
      expect(attempt.reproduction.value).to eq(REPRO)
    end

    it "refuses a verification that re-ran a different command" do
      log_bug
      claim
      fix

      expect { verify(rerun: "rspec spec/new_spec.rb") }
        .to raise_error(Hecks::Runtime::GivenNotMet, /not the one recorded/)
    end

    it "refuses a verification whose reproduction still fails" do
      log_bug
      claim
      fix

      expect { verify(rerun_result: "failed") }.to raise_error(Hecks::Runtime::GivenNotMet, /still fails/)
    end

    it "accepts a verification that re-ran the same command and passed" do
      log_bug
      claim
      fix
      verify

      expect(attempt.status).to eq("verified")
    end
  end
end
