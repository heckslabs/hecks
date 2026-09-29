require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tmpdir"

# The committed approval of an edge: `translations/<edge>.approval`. Ruby writes and reads it, the
# mint applies it, and rust/host applies the same file from ir.json.
RSpec.describe Hecks::Translation::ApprovalFile do
  PARITY_FIXTURE = File.expand_path("../fixtures/approval_parity/ir.json", __dir__).freeze

  COMPUTED_EDGE = <<~RUBY.freeze
    Hecks.data_translation("LedgerCompute", from: "aaaaaa", to: "bbbbbb") do
      aggregate("Account") do
        compute "score", to: "doubled", sql: "jsonb_build_object('value', (score::jsonb->>'value')::int * 2)"
        rekey sql: "state->>'kind'"
      end
    end
  RUBY

  RENAMED_EDGE = <<~RUBY.freeze
    Hecks.data_translation("LedgerRename", from: "cccccc", to: "dddddd") do
      aggregate("Account") { rename :cost, to: :amount }
    end
  RUBY

  REHEARSAL = { "snapshot" => "rds:ledger-2026-09-28", "host_version" => "3.0.0",
                "result" => "pass", "at" => "2026-09-28T12:00:00Z" }.freeze

  def registry_with(source)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks::Ports::Loading.bootstrap.load_library
      eval(source)
    end
    registry
  end

  let(:registry) { registry_with(COMPUTED_EDGE) }
  let(:edge) { registry.translations.first }

  describe ".build" do
    it "binds to the edge's digest, who approved it, when, and the rehearsal" do
      document = described_class.build(edge: edge, approved_by: "Ada <ada@example.com>",
                                       approved_at: "2026-09-28T12:30:00Z", rehearsal: REHEARSAL)

      expect(document).to eq(
        "edge" => "aaaaaa-bbbbbb", "edge_digest" => Hecks::Translation::Audit.edge_digest(edge),
        "approved_by" => "Ada <ada@example.com>", "approved_at" => "2026-09-28T12:30:00Z", "rehearsal" => REHEARSAL
      )
    end

    it "requires a rehearsal that passed for an edge with a compute or rekey rule" do
      [nil, {}, REHEARSAL.merge("result" => "fail"), REHEARSAL.merge("snapshot" => " ")].each do |rehearsal|
        expect do
          described_class.build(edge: edge, approved_by: "Ada", approved_at: "2026-09-28T12:30:00Z", rehearsal: rehearsal)
        end.to raise_error(ArgumentError, /approved on a rehearsal that passed/)
      end
    end

    it "needs no rehearsal for an edge whose rules an audit's samples can vouch for" do
      renamed = registry_with(RENAMED_EDGE).translations.first

      document = described_class.build(edge: renamed, approved_by: "Ada", approved_at: "2026-09-28T12:30:00Z")

      expect(document.keys).to eq(%w[edge edge_digest approved_by approved_at])
    end
  end

  describe "on disk" do
    around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

    def approve!(rehearsal: REHEARSAL)
      document = described_class.build(edge: edge, approved_by: "Ada", approved_at: "2026-09-28T12:30:00Z",
                                       rehearsal: rehearsal)
      described_class.write!(@dir, edge, document)
    end

    it "lives beside the edge as translations/<edge>.approval" do
      expect(approve!).to eq(File.join(@dir, "translations", "aaaaaa-bbbbbb.approval"))
      expect(JSON.parse(File.read(File.join(@dir, "translations",
                                            "aaaaaa-bbbbbb.approval")))).to include("edge" => "aaaaaa-bbbbbb")
    end

    it "applies to the edge whose digest it holds, and to no other" do
      approve!

      expect(described_class.applicable(@dir, edge)).to include("approved_by" => "Ada")
      changed = registry_with(COMPUTED_EDGE.sub("* 2", "* 3")).translations.first
      expect(described_class.applicable(@dir, changed)).to be_nil
    end

    it "does not apply once its rehearsal was edited to a failure" do
      path = approve!
      File.write(path, File.read(path).sub('"pass"', '"fail"'))

      expect(described_class.applicable(@dir, edge)).to be_nil
    end

    it "skips a file that is not JSON, since it approves nothing" do
      FileUtils.mkdir_p(File.join(@dir, "translations"))
      File.write(File.join(@dir, "translations", "junk.approval"), "not json")

      expect(described_class.read_all(@dir)).to eq([])
      expect(described_class.applicable(@dir, edge)).to be_nil
    end

    it "applies to nothing when there is no directory" do
      expect(described_class.applicable(nil, edge)).to be_nil
    end
  end

  # rust/host reads the same file from ir.json and must reach the same digest. The fixture holds
  # what Ruby exports for the edge, and the approval Ruby writes for it; `approval.rs` proves the
  # digest of that edge is that approval's.
  describe "the digest rust/host agrees on" do
    def exported
      document = described_class.build(edge: edge, approved_by: "Ada <ada@example.com>",
                                       approved_at: "2026-09-28T12:30:00Z", rehearsal: REHEARSAL)
      JSON.pretty_generate(
        "translations" => JSON.parse(JSON.generate(Hecks::Projector::Exporter.translations(registry))),
        "approvals"    => [document]
      )
    end

    it "matches the committed parity fixture" do
      File.write(PARITY_FIXTURE, "#{exported}\n") if ENV["GOLDEN"] == "rewrite"

      expect(File.read(PARITY_FIXTURE)).to eq("#{exported}\n")
    end

    it "is the digest rust/host pins for the same edge" do
      expect(Hecks::Translation::Audit.edge_digest(edge))
        .to eq("3803f00c11d5c613d2abb4f289a8a668e5885d2f36681134e509ed98408d520c")
    end
  end
end
