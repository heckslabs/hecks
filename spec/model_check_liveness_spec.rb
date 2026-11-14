require "spec_helper"
require "tempfile"
require "hecks/tools/model_check"

# model_check's words about waiting: a lifecycle state that is not ended is passed through by the
# reactions to entering it, marked `:rests`, or a wait, and a wait needs a timeout row. The rows
# that name a state are held to it: the opening event enters it and the closing events cover
# every way out.
RSpec.describe "model_check over waits" do
  LIVENESS_ERRAND = File.join(InMemoryDomain::ROOT, "spec/corpus/asks/domain/bluebook").freeze
  PARK_TRANSITION = %(      transition "Park"    => "parked",    from: "requested"\n).freeze
  PARK_COMMAND = <<~BLUEBOOK.freeze
    command "Park" do
      goal "Leave the job waiting on a person"
      reference_to Job
      emits JobParked
    end

  BLUEBOOK
  ABANDON_LINE = %(      transition "Abandon" => "abandoned", from: "requested"\n).freeze

  # The Errand bluebook, with a `parked` state only a person leaves and any further edits.
  def errand_source(edits)
    source = File.read(File.join(LIVENESS_ERRAND, "errand.bluebook"))
    source = source.sub(ABANDON_LINE, "#{ABANDON_LINE}#{PARK_TRANSITION}")
    source = source.sub(%(    command "Settle" do), %(#{PARK_COMMAND}    command "Settle" do))
    edits.reduce(source) { |text, (from, to)| text.sub(from, to) }
  end

  def errand(edits)
    file = Tempfile.new(["errand_liveness", ".bluebook"])
    file.write(errand_source(edits))
    file.flush
    load_errand(file.path)
  ensure
    file&.close!
  end

  def load_errand(bluebook)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, bluebook, File.join(LIVENESS_ERRAND, "errand.hecksagon")].each { |f| Kernel.load(f) }
    end
    registry.bluebook("Errand")
  end

  # Each liveness finding as its kind, severity and the state or row it names.
  def liveness(edits = {}, **context)
    found = Hecks::Bluebook::ModelCheck.liveness_findings(errand(edits), context[:timeouts], held: context[:held])
    found.map { |f| [f.kind, f.severity, f.message[/"(\w+)"/, 1]] }
  end

  def row(**fields) = { kind: "parked-job", aggregate: "Errand::Job", **fields }

  def mark(states) = { ABANDON_LINE => %(#{ABANDON_LINE}      mark :rests, #{states}\n) }

  describe "a planted state only a person leaves" do
    it "is a wait with no timeout, as a warning" do
      expect(liveness).to include([:wait_without_timeout, :warning, "parked"])
    end

    it "is an error once the bluebook's waits are held" do
      expect(liveness(held: true)).to include([:wait_without_timeout, :error, "parked"])
    end

    it "passes once a timeout row names it" do
      timed = liveness(timeouts: [row(state: "parked", opens: "JobParked", closes: "")], held: true)

      expect(timed.map(&:last)).not_to include("parked")
    end
  end

  describe "a state the reactions to entering it leave" do
    it "is not a wait when an ask's answer and refusal each trigger a transition out" do
      expect(liveness.map(&:last)).not_to include("requested")
    end

    it "is a wait when a policy on the way has a where" do
      guarded = { %(on      "Job.JobRan"\n) => %(on      "Job.JobRan"\n    where   { result.value == "ok" }\n) }

      expect(liveness(guarded)).to include([:wait_without_timeout, :warning, "requested"])
    end

    it "is a wait when the refusal triggers nothing" do
      deaf = { %(on      "Job.JobRefused"\n) => %(on      "Job.JobSettled"\n) }

      expect(liveness(deaf)).to include([:wait_without_timeout, :warning, "requested"])
    end
  end

  describe "a timeout row that names a state" do
    it "is refused when its opening event does not enter the state" do
      rows = [row(state: "parked", opens: "JobRequested", closes: "")]

      expect(liveness(timeouts: rows)).to include([:timeout_opens_elsewhere, :error, "JobRequested"])
    end

    it "is refused when its closing events miss a way out of the state" do
      rows = [row(state: "requested", opens: "JobRequested", closes: "JobSettled,JobParked")]

      expect(liveness(timeouts: rows)).to include([:timeout_open_exit, :error, "requested"])
    end

    it "is refused when the lifecycle has no such state" do
      rows = [row(state: "lost", opens: "JobRequested", closes: "")]

      expect(liveness(timeouts: rows)).to include([:timeout_unknown_state, :error, "lost"])
    end

    it "is left alone when it names another bluebook's aggregate" do
      rows = [row(aggregate: "Other::Job", state: "lost", opens: "JobRequested", closes: "")]

      expect(liveness(timeouts: rows).map(&:first)).not_to include(:timeout_unknown_state)
    end
  end

  describe "a state marked :rests" do
    it "is not a wait" do
      expect(liveness(mark(%("parked"))).map(&:last)).not_to include("parked")
    end

    it "is refused when the reactions to entering it carry every record out" do
      expect(liveness(mark(%("requested")))).to include([:rests_contradicted, :error, "requested"])
    end

    it "is refused when a timeout row times it" do
      rows = [row(state: "parked", opens: "JobParked", closes: "")]

      expect(liveness(mark(%("parked")), timeouts: rows)).to include([:rests_contradicted, :error, "parked"])
    end

    it "is refused by the builder when it is no state of the lifecycle" do
      expect { liveness(mark(%("nowhere"))) }.to raise_error(Hecks::Bluebook::DSL::Malformed, /mark :rests names "nowhere"/)
    end
  end

  describe "the Hecks bluebook's own rows" do
    let(:hecks) { boot_hecks_in_memory.registry.bluebook("Hecks") }
    let(:rows) { Hecks::Tools::ModelCheck.timeout_rows(hecks) }

    def hecks_findings(timeouts) = Hecks::Bluebook::ModelCheck.liveness_findings(hecks, timeouts, held: true)

    def waits_of(timeouts, subject)
      hecks_findings(timeouts).select { |f| f.kind == :wait_without_timeout && f.subject == subject }.map(&:message)
    end

    it "name states their opening and closing events agree with" do
      expect(hecks_findings(rows).reject { |f| f.kind == :wait_without_timeout }.map(&:to_s)).to be_empty
    end

    it "time a started AgentRun, which is a wait without them", :aggregate_failures do
      expect(waits_of(rows, "AgentRun")).to be_empty
      expect(waits_of([], "AgentRun")).to include(a_string_starting_with('"started" can hold a record forever'))
    end

    it "are read by the model check command, which finds none in a bluebook that declares none" do
      expect([rows.size, Hecks::Tools::ModelCheck.timeout_rows(load_errand(File.join(LIVENESS_ERRAND, "errand.bluebook")))])
        .to eq([hecks.aggregate("StallWatch").value_objects.find { |o| o.hecks_name == "StallKind" }.members.size, nil])
    end
  end
end
