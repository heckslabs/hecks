require "hecks"
require_relative "../../support/postgres_probe"
require_relative "../../support/era_registry_loading"

# `mints_era` leaves the command and moves to the persistence binding: a world's
# `persisted_by("Postgres") { mints_era "Maintenance.MintEra" }` names the commands whose own
# record an unminted boot may write. The bluebook word still works; given together the two must
# agree, and a name that matches no command refuses by name.
RSpec.describe "the mints_era binding" do
  include EraRegistryLoading

  let(:template) do
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Maintenance" do
          identified_by :run
          attribute :run, Run

          value_object "Run" do
            attribute :label, String
          end

          command "MintEra" do
            FLAG
            attribute :run, Run
            emits "MintRequested"
          end

          command "Note" do
            attribute :run, Run
            emits "Noted"
          end
        end
      end
    BLUEBOOK
  end

  def ledger(flagged: true)
    load_registry(template.sub("FLAG", flagged ? "mints_era true" : "")).bluebooks.values.first
  end

  def check(settings, flagged: true) = Hecks::Ports::Persistence::MintDoor.check!(ledger(flagged: flagged), settings)

  describe "reading the names" do
    it "reads one name, a list, either spelling of the key, and nothing when absent", :aggregate_failures do
      door = Hecks::Ports::Persistence::MintDoor
      expect(door.names({ mints_era: "Maintenance.MintEra" })).to eq(["Maintenance.MintEra"])
      expect(door.names({ "mints_era" => %w[A.B C.D] })).to eq(%w[A.B C.D])
      expect(door.names({ database: "x" })).to eq([])
    end

    it "answers true for a named command and false for any other", :aggregate_failures do
      door = Hecks::Ports::Persistence::MintDoor
      settings = { mints_era: ["Maintenance.MintEra"] }
      expect(door.declared?(settings, "Maintenance", "MintEra")).to be(true)
      expect(door.declared?(settings, "Maintenance", "Note")).to be(false)
      expect(door.declared?({}, "Maintenance", "MintEra")).to be(false)
    end
  end

  describe "checking the binding against the bluebook" do
    it "passes when the world names the command and the bluebook agrees" do
      expect { check({ mints_era: "Maintenance.MintEra" }) }.not_to raise_error
    end

    it "passes when the world names the command and the bluebook says nothing" do
      expect { check({ mints_era: "Maintenance.MintEra" }, flagged: false) }.not_to raise_error
    end

    it "passes when the world says nothing: the bluebook word alone still works" do
      expect { check({ database: "x" }) }.not_to raise_error
    end

    it "refuses by name a world that names a command the domain does not declare" do
      expect { check({ mints_era: "Maintenance.MintErra" }) }
        .to raise_error(Hecks::Runtime::WiringError, /names Maintenance\.MintErra.*Ledger declares no such command/m)
    end

    it "refuses by name a command the bluebook flags and the world's list leaves out" do
      expect { check({ mints_era: "Maintenance.Note" }) }
        .to raise_error(Hecks::Runtime::WiringError, /Maintenance\.MintEra declares `mints_era true`.*not name it/m)
    end
  end

  # The interpreter asks the repository, and the repository its adapter, so the allowance is
  # read at the adapter the boot built and not off the command alone.
  describe "the allowance a save carries" do
    let(:persisting) { Class.new { include Hecks::Runtime::CommandInterpreter::Persisting }.new }
    let(:context_class) do
      Struct.new(:repository, :command, :command_hecks_name, :aggregate_hecks_name, :instance, :instance_version,
                 :strategy, keyword_init: true)
    end

    def saved(minted) = [:record, { expected_version: nil, mints_era: minted }]

    def save_with(declares:, flagged:)
      adapter = double(append: nil, project: nil, entries: [])
      allow(adapter).to receive(:mints_era_declared?).with("Maintenance", "MintEra").and_return(declares)
      repo = Hecks::Ports::Persistence::AppendOnly.new(adapter)
      allow(repo).to receive(:save)
      ctx = context_class.new(repository: repo, command: double(mints_era?: flagged), command_hecks_name: "MintEra",
                              aggregate_hecks_name: "Maintenance", instance: :record, instance_version: nil)
      persisting.send(:persist_instance, ctx)
      repo
    end

    it "is true when the binding names the command, though the command says nothing" do
      expect(save_with(declares: true, flagged: false)).to have_received(:save).with(*saved(true))
    end

    it "is true when the command says it, though the binding names nothing" do
      expect(save_with(declares: false, flagged: true)).to have_received(:save).with(*saved(true))
    end

    it "is false when neither says it" do
      expect(save_with(declares: false, flagged: false)).to have_received(:save).with(*saved(false))
    end

    it "is false for an adapter that has no binding to ask" do
      repo = Hecks::Ports::Persistence::AppendOnly.new(double(append: nil, project: nil, entries: []))
      expect(repo.mints_era_declared?("Maintenance", "MintEra")).to be(false)
    end
  end

  # The boot gate runs the check before it reads or writes any database, so a disagreement
  # refuses the boot by name, not at the first write.
  describe "PostgresRevision's boot gate" do
    before do
      require "hecks/adapters/driven/postgres_era"
    rescue LoadError
      skip "PostgresRevision is not loadable here"
    end

    it "refuses a binding that leaves a flagged command out, before reaching the database" do
      allow(Hecks::Adapters::PostgresRevision::LineageManager).to receive(:check!)
      expect do
        Hecks::Adapters::PostgresRevision.era_check!(registry: nil, bluebook: ledger, current_text: "",
                                                     settings: { mints_era: "Maintenance.Other" })
      end.to raise_error(Hecks::Runtime::WiringError, /Maintenance\.Other/)
    end

    it "reads the names off its own settings" do
      adapter = Hecks::Adapters::PostgresRevision.allocate
      adapter.instance_variable_set(:@settings, { mints_era: "Maintenance.MintEra" })
      expect(adapter.mints_era_declared?("Maintenance", "MintEra")).to be(true)
    end

    it "declares the mints_era field, so a world may set it" do
      path = File.expand_path("../../../lib/hecks/adapters/driven/postgres.adapter", __dir__)
      expect(File.read(path)).to include("field :mints_era")
    end
  end
end
