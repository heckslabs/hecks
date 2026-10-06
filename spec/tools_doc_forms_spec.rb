require "spec_helper"
require "hecks/tools/tools_doc"

# The launcher form each retired script became, as `hecks project_tools_doc` renders it from the
# RetiredScript rows and the command's own arguments.
RSpec.describe Hecks::Tools::ToolsDoc do
  let(:forms) { described_class.forms(root: InMemoryDomain::ROOT) }

  it "gives every form as a launcher call" do
    expect(forms.reject { |_, form| form.start_with?("hecks ") }.keys).to eq([])
  end

  it "spells the QualityControl scripts as the chapter's own verbs", :aggregate_failures do
    expect(forms.fetch("qa_open_pr")).to include("hecks quality_control patch.open ", "hecks quality_control improvement.open ")
    expect(forms.fetch("qa_log_bug")).to start_with("hecks quality_control bug.log ")
    expect(forms.fetch("qa_sweep")).to start_with("hecks quality_control sweep.run ")
      .and include("hecks quality_control target.release ")
  end

  it "spells the QualityControl seeds and the ledger migration as the chapter's own verbs", :aggregate_failures do
    expect(forms.fetch("qa_seed_angles")).to eq("hecks quality_control angle.seed")
    expect(forms.fetch("qa_seed_targets")).to eq("hecks quality_control target.seed")
    expect(forms.fetch("qa_postgres_migrate")).to include("migrate_ledger_from_heki")
  end

  it "spells the verbs the launcher names its own way by that name", :aggregate_failures do
    expect(forms.fetch("console")).to start_with("hecks console")
    expect(forms.fetch("hecks_mcp_door")).to start_with("hecks mcp")
    expect(forms.fetch("stores")).to eq("hecks stores <domain>")
    expect(forms.fetch("model_check")).to include("[--strict]")
  end

  it "makes the first argument the bare word and names the rest", :aggregate_failures do
    expect(forms.fetch("project")).to eq("hecks operation.refresh_projections <subject>")
    expect(forms.fetch("check_era")).to eq("hecks host.check_era <host> expected= [timeout=]")
    expect(forms.fetch("deploy_template_diff")).to start_with("hecks deploy template_comparison.diff <before> after=")
    expect(forms.fetch("project_deploy")).to start_with("hecks deploy recipe.project <domain> ")
  end

  it "shows a switch as a flag, bare for --confirm, and leaves out the minted run key", :aggregate_failures do
    expect(forms.fetch("merge_tail")).to eq("hecks era.merge_tail <domain> [winners=] --confirm")
    expect(forms.values.join(" ")).not_to match(/(?<![a-z_])run=/)
  end

  it "keeps a row's own note and pass-through flags beside the form", :aggregate_failures do
    expect(forms.fetch("release")).to include("(without --confirm, the old --dry-run)")
    novelty = forms.fetch("qa_domain_novelty")

    expect(novelty).to include('[arguments="--against PATH …"]')
    expect(novelty.scan("arguments").size).to eq(1)
    expect(forms.fetch("qa_concurrency_racer")).to include("(not user-facing; ProcessPool starts it)")
  end

  it "has no form for a command no script preceded" do
    expect(forms.key?("(new)")).to be(false)
  end
end
