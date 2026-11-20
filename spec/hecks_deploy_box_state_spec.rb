require "spec_helper"
require "json"
require_relative "support/box_state_stand_in"

# `hecks deploy box_roll.box_state`: the Deploy bluebook's read-only BoxState query asks the
# BoxState port, whose adapter reads the box through a stand-in `aws` program in a scratch
# directory. It answers facts and no verdict. Nothing reaches AWS and no record is written.
RSpec.describe "the Deploy bluebook's BoxState query", :io do
  include_context "with a scratch box"

  it "is one more query on BoxRoll, with no command of its own", :aggregate_failures do
    roll = @hecks.registry.bluebook("Deploy").aggregate("BoxRoll")

    expect(roll.queries.map(&:hecks_name)).to eq(%w[Verdict Flagged BoxState])
    expect(roll.commands.map(&:hecks_name)).to eq(%w[Run Complete Flag Verify FlagSmoke])
  end

  it "is listed under BoxRoll's queries in hecks deploy --help" do
    help, = ask(words: %w[deploy --help])

    expect(help).to match(/^\s+box_state\s+The app box as it is now/)
  end

  it "is answered by the Deploy bluebook booted alone" do
    alone = without_local_overlay { Hecks.boot(File.expand_path("../lib/hecks/deploy", __dir__)) }
    out, = ask("project=#{box.project}", runtime: alone, words: %w[box_roll.box_state])

    expect(JSON.parse(out).first.fetch("box")).to eq("i-0abc")
  end

  describe "what the BoxState query answers" do
    it "answers what runs on the box, its commit, its restore point and that nothing is rolling" do
      expect(state).to eq(
        "box" => "i-0abc", "running" => "website website-old Up 3 minutes\ncms cms-old Up 3 minutes",
        "commit" => BoxStateStandIn::REVISION, "rolling" => false,
        "restore_point" => "widget-db restorable to 2026-11-20T10:00:00+00:00 (backups kept 7 days)"
      )
    end

    it "says the box is rolling while another command has not ended there" do
      box.answer(:in_progress, "cmd-roll\n")

      expect(state.fetch("rolling")).to be(true)
    end

    it "names every revision when the containers run different commits" do
      box.answer(:containers, "website\tr/w:website-new\tabc\tUp 2 minutes\ncms\tr/c:cms-old\tdef\tRestarting (1)\n")

      expect(state.values_at("commit", "running"))
        .to eq(["abc def", "website website-new Up 2 minutes\ncms cms-old Restarting (1)"])
    end
  end

  describe "what the BoxState query leaves empty" do
    it "answers an empty commit for images built without a revision" do
      box.answer(:containers, "website\tr/w:website-old\t\tUp 3 minutes\n")

      expect(state.fetch("commit")).to eq("")
    end

    it "answers an empty restore point when the backups cannot be read" do
      box.answer(:backups, nil)

      expect(state.fetch("restore_point")).to eq("")
    end

    it "only reads: it lists the box's commands before it sends its own listing", :aggregate_failures do
      state

      expect(box.calls.uniq).to eq(BoxStateStandIn::READS)
      expect(box.sent).to include("--comment hecks box state", "docker compose -f compose.json ps")
      expect(box.sent).not_to match(/ up | pull| restart| rm /)
    end
  end

  describe "a box the BoxState query cannot read" do
    it "is refused when the stack has no instance, sending nothing to the box", :aggregate_failures do
      box.answer(:instance, "None\n")

      expect(ask("project=#{box.project}")).to match([/no instance in stack widget-box/, 1])
      expect(box.calls).to eq(["cloudformation describe-stacks"])
    end

    it "is refused when the box does not answer" do
      box.answer(:command_status, "Failed\n")

      expect(ask("project=#{box.project}")).to match([/the box did not answer: command cmd-1 ended Failed/, 1])
    end

    it "is refused when the project has no deploy-box.sh, asking AWS nothing", :aggregate_failures do
      expect(ask("project=#{box.dir}/bin")).to match([/no deploy-box.sh under/, 1])
      expect(box.calls).to be_empty
    end
  end
end
