# frozen_string_literal: true

require "stringio"
require "hecks/three_zero"

RSpec.describe Hecks::ThreeZero do
  let(:root) { File.expand_path("..", __dir__) }
  let(:scripts) { Dir[File.join(root, "bin/*")].map { |path| File.basename(path) }.sort }

  def terminal
    StringIO.new.tap { |io| io.define_singleton_method(:tty?) { true } }
  end

  it "names a 3.0 form for every bin/ script, and for nothing else" do
    expect(described_class::FORMS.keys.sort).to eq(scripts)
  end

  it "gives every form as a launcher call, except the one script that is not user-facing" do
    forms = described_class::FORMS.except("qa_concurrency_racer")

    expect(forms.reject { |_, form| form.start_with?("hecks ") }.keys).to eq([])
  end

  it "spells the QualityControl scripts as the chapter's own verbs" do
    forms = described_class::FORMS

    expect(forms.fetch("qa_open_pr")).to include("hecks quality_control patch.open ")
      .and include("hecks quality_control improvement.open ")
    expect(forms.fetch("qa_log_bug")).to start_with("hecks quality_control log ")
    expect(forms.fetch("qa_sweep")).to start_with("hecks quality_control ask run ")
      .and include("hecks quality_control release <target>")
    expect(forms.fetch("qa_seed_angles")).to eq("hecks quality_control angle.seed")
    expect(forms.fetch("qa_seed_targets")).to eq("hecks quality_control target.seed")
    expect(forms.fetch("qa_postgres_migrate")).to include("migrate_ledger_from_heki")
  end

  it "spells the verbs whose first argument is not the domain with the argument named" do
    forms = described_class::FORMS

    expect(forms.fetch("console")).to eq("hecks console [subject=<domain>]")
    expect(forms.fetch("project")).to eq("hecks refresh_projections subject=<domain>")
    expect(forms.fetch("deploy_template_diff")).to start_with("hecks deploy diff ")
    expect(forms.fetch("project_deploy")).to start_with("hecks deploy project ")
  end

  it "keeps the positional forms of the verbs the launcher hands to the classic CLI" do
    expect(described_class::FORMS.fetch("model_check")).to include("[--profile client]")
    expect(described_class::FORMS.fetch("project_diagrams")).to eq(
      "hecks project_diagrams <domain-path> <ChapterName>"
    )
  end

  it "is announced by every bin/ script, under its own name" do
    scripts.each do |name|
      expect(File.read(File.join(root, "bin", name))).to include("Hecks::ThreeZero.notice(#{name.inspect})"), name
    end
  end

  it "tells a terminal what a script becomes" do
    io = terminal
    described_class.notice("compact", io: io, env: {})
    expect(io.string).to include("bin/compact is removed in 3.0.0").and include("hecks compact <domain>")
  end

  it "says nothing to a pipe, so piped output and CI logs stay clean" do
    io = StringIO.new
    described_class.notice("compact", io: io, env: {})
    expect(io.string).to be_empty
  end

  it "says nothing when HECKS_NO_3_0_NOTICE is set" do
    io = terminal
    described_class.notice("compact", io: io, env: { "HECKS_NO_3_0_NOTICE" => "1" })
    expect(io.string).to be_empty
  end

  it "gives an exe/hecks route its 3.0 form, through the script it runs" do
    io = terminal
    described_class.route_notice("mcp", io: io, env: {})
    expect(io.string).to include("`hecks mcp [--stdio]`")
  end

  it "comments a generated Makefile or script with the 3.0 form of each bin/ call, and leaves other files alone" do
    files = { "Makefile" => "deploy:\n\tbin/project_wasm x\n", "run.sh" => "#!/bin/sh\nbin/check_era a b\n",
              "template.yaml" => "bin/fuzz\n" }
    out = described_class.annotate_deploy_files(files)

    expect(out["Makefile"]).to start_with("# hecks 3.0.0 removes bin/").and include("bin/project_wasm becomes")
    expect(out["run.sh"]).to start_with("#!/bin/sh\n# hecks 3.0.0 removes bin/")
    expect(out["template.yaml"]).to eq("bin/fuzz\n")
  end
end
