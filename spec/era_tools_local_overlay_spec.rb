require "spec_helper"
require "tmpdir"
require_relative "../lib/hecks/hecks/adapters/journal_store"
require "hecks/tools/translation_scaffold"
require "hecks/tools/era_reattest"
require "hecks/tools/era_projection_backfill"
require "hecks/tools/translation_audit"
require "hecks/tools/tail_merge"

# A domain on Memory by default that a copy opts into PostgresEra with `*.local.hecksagon` and
# `*.local.world` (ADR 0136). The era tools read the held journal, so they must load the domain with
# the same overlay the runtime applies, or they report it bound to Memory.
RSpec.describe "the era tools and a local overlay" do
  let(:bluebook_source) do
    <<~BLUEBOOK
      Hecks.bluebook "Overlaid" do
        aggregate "Thing" do
          identified_by :name
          attribute :name, ThingName
          value_object "ThingName" do
            attribute :value, String
          end
          command "Create" do
            attribute :name, ThingName
            sets :name
            emits "ThingCreated"
          end
        end
      end
    BLUEBOOK
  end
  let(:local_hecksagon) { %(Hecks.hecksagon "Overlaid" do\n  persisted_by "PostgresEra"\nend\n) }

  def domain_dir(with_local:)
    dir = Dir.mktmpdir("overlaid-")
    File.write(File.join(dir, "overlaid.bluebook"), bluebook_source)
    File.write(File.join(dir, "overlaid.local.hecksagon"), local_hecksagon) if with_local
    dir
  end

  def adapter_after(tool, dir)
    registry, bluebook, = tool.load_domain(dir)
    Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, bluebook.aggregates.first).adapter
  end

  describe "the launcher's held domain" do
    %i[translated bare scaffold].each do |mode|
      it "sees the PostgresEra a local hecksagon names in #{mode} mode" do
        held = Hecks::Adapters::JournalStore::HeldDomain.open(domain_dir(with_local: true), mode: mode, environment: nil)
        expect(held.adapter_name).to eq("PostgresEra")
      end
    end
  end

  [Hecks::Tools::TranslationScaffold, Hecks::Tools::EraReattest, Hecks::Tools::EraProjectionBackfill,
   Hecks::Tools::TranslationAudit, Hecks::Tools::TailMerge].each do |tool|
    describe tool do
      it "sees the PostgresEra a local hecksagon names" do
        expect(adapter_after(tool, domain_dir(with_local: true))).to eq("PostgresEra")
      end

      it "stays in Memory when no local file opts in" do
        expect(adapter_after(tool, domain_dir(with_local: false))).to eq("Memory")
      end
    end
  end
end
