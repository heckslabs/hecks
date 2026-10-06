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

  # Builds the approval for the computed edge, Ada approving at noon unless an override says otherwise.
  def build_with(**overrides)
    described_class.build(edge: edge, approved_by: "Ada", approved_at: "2026-09-28T12:30:00Z",
                          rehearsal: REHEARSAL, **overrides)
  end

  describe ".build" do
    it "binds to the edge's digest, who approved it, when, and the rehearsal" do
      document = build_with(approved_by: "Ada <ada@example.com>")

      expect(document).to eq("edge" => "aaaaaa-bbbbbb", "edge_digest" => Hecks::Translation::Audit.edge_digest(edge),
                             "approved_by" => "Ada <ada@example.com>", "approved_at" => "2026-09-28T12:30:00Z",
                             "rehearsal" => REHEARSAL)
    end

    it "requires a rehearsal that passed for an edge with a compute or rekey rule" do
      [nil, {}, REHEARSAL.merge("result" => "fail"), REHEARSAL.merge("snapshot" => " ")].each do |rehearsal|
        expect { build_with(rehearsal: rehearsal) }
          .to raise_error(ArgumentError, /approved on a rehearsal that passed/)
      end
    end

    it "refuses a rehearsal field that is not a String, as rust/host does" do
      [{ "snapshot" => 42 }, { "host_version" => 3.0 }, { "at" => nil }].each do |bad|
        expect { build_with(rehearsal: REHEARSAL.merge(bad)) }
          .to raise_error(ArgumentError, /approved on a rehearsal that passed/)
      end
    end

    it "names who approved it" do
      ["", " ", nil, 7].each do |who|
        expect { build_with(approved_by: who) }.to raise_error(ArgumentError, /names who approved it/)
      end
    end

    it "names when it was approved, as a time that exists" do
      ["", "yesterday", nil, "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-09-28T25:00:00Z", "2026-09-28"].each do |at|
        expect { build_with(approved_at: at) }.to raise_error(ArgumentError, /names who approved it/)
      end
    end

    it "accepts a time with a fractional second and an offset" do
      expect(build_with(approved_at: "2026-09-28T12:30:00.5+02:00")).to include("approved_by" => "Ada")
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
      described_class.write!(@dir, edge, build_with(rehearsal: rehearsal))
    end

    it "lives beside the edge as translations/<edge>.approval", :aggregate_failures do
      expect(approve!).to eq(File.join(@dir, "translations", "aaaaaa-bbbbbb.approval"))
      expect(JSON.parse(File.read(File.join(@dir, "translations",
                                            "aaaaaa-bbbbbb.approval")))).to include("edge" => "aaaaaa-bbbbbb")
    end

    it "applies to the edge whose digest it holds, and to no other", :aggregate_failures do
      approve!

      expect(described_class.applicable(@dir, edge, host_version: "3.0.0")).to include("approved_by" => "Ada")
      changed = registry_with(COMPUTED_EDGE.sub("* 2", "* 3")).translations.first
      expect(described_class.applicable(@dir, changed, host_version: "3.0.0")).to be_nil
    end

    it "applies on a host of the rehearsal's major.minor" do
      approve!

      %w[3.0.0 3.0.9 3.0.1-rc.1].each do |host|
        expect(described_class.applicable(@dir, edge, host_version: host)).to include("approved_by" => "Ada")
      end
    end

    it "does not apply on a host of another major.minor" do
      approve!

      %w[2.9.0 3.1.0 4.0.0].each do |host|
        expect(described_class.applicable(@dir, edge, host_version: host)).to be_nil
      end
    end

    it "refuses a host of another major.minor, naming both versions" do
      approve!

      expect(described_class.host_mismatch(@dir, edge, host_version: "3.1.2")).to eq(
        "the rehearsal ran on Hecks 3.0.0, but this host is Hecks 3.1.2; a rehearsal counts only on a " \
        "host of the same major.minor (3.1.x) — re-run the rehearsal on this host and approve again"
      )
    end

    it "does not refuse a host of the rehearsal's major.minor" do
      approve!

      expect(described_class.host_mismatch(@dir, edge, host_version: "3.0.4")).to be_nil
    end

    ["three", "3", "v3.0.0"].each do |bad|
      it "does not apply a rehearsal whose host_version is #{bad.inspect}, not a version" do
        path = approve!
        File.write(path, File.read(path).sub('"3.0.0"', %("#{bad}")))

        expect(described_class.applicable(@dir, edge, host_version: "3.0.0")).to be_nil
      end
    end

    it "checks against the running release by default", :aggregate_failures do
      approve!(rehearsal: REHEARSAL.merge("host_version" => Hecks::VERSION))

      expect(described_class.applicable(@dir, edge)).to include("approved_by" => "Ada")
      expect(described_class::HOST_RELEASE).to eq(Hecks::VERSION)
    end

    it "does not apply once its rehearsal was edited to a failure" do
      path = approve!
      File.write(path, File.read(path).sub('"pass"', '"fail"'))

      expect(described_class.applicable(@dir, edge, host_version: "3.0.0")).to be_nil
    end

    [['"approved_by": "Ada"', '"approved_by": ""'], ['"2026-09-28T12:30:00Z"', '"someday"'],
     ['"rds:ledger-2026-09-28"', "20260928"], ['"3.0.0"', '""']].each do |from, to|
      it "does not apply once #{from} is edited to #{to}, blanking a field or making it a number" do
        path = approve!
        File.write(path, File.read(path).sub(from, to))

        expect(described_class.applicable(@dir, edge, host_version: "3.0.0")).to be_nil
      end
    end

    it "skips a file that is not JSON, since it approves nothing", :aggregate_failures do
      FileUtils.mkdir_p(File.join(@dir, "translations"))
      File.write(File.join(@dir, "translations", "junk.approval"), "not json")

      expect(described_class.read_all(@dir)).to eq([])
      expect(described_class.applicable(@dir, edge, host_version: "3.0.0")).to be_nil
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
      JSON.pretty_generate(
        "translations" => JSON.parse(JSON.generate(Hecks::Projector::Exporter.translations(registry))),
        "approvals"    => [build_with(approved_by: "Ada <ada@example.com>")]
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
