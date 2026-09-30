# frozen_string_literal: true

require "hecks/three_zero"

RSpec.describe Hecks::ThreeZero do
  let(:root) { File.expand_path("..", __dir__) }

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
end
