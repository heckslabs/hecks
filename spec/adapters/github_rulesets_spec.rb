require "hecks"
require_relative "../../lib/hecks/hecks/adapters/github_rulesets"

# Transport only: the runner is a recorder, so the suite never shells out to a real `gh`. The `gh`
# arguments, the request bodies and the comparison run for real.
RSpec.describe Hecks::Adapters::GithubRulesets do
  subject(:rulesets) { described_class.new(runner: runner) }

  let(:calls) { [] }
  let(:replies) { {} }
  let(:runner) do
    lambda do |args, stdin|
      calls << [args, stdin]
      replies.fetch(args) { ["", "no reply for #{args.inspect}", false] }
    end
  end
  let(:projected) do
    { "name" => "lane-stable", "target" => "branch", "enforcement" => "active",
      "conditions" => { "ref_name" => { "include" => ["refs/heads/stable"], "exclude" => [] } },
      "bypass_actors" => [{ "actor_id" => 15_368, "actor_type" => "Integration", "bypass_mode" => "always" }],
      "rules" => [{ "type" => "deletion" }, { "type" => "non_fast_forward" }, { "type" => "update" }] }
  end
  let(:list) { ["api", "repos/{owner}/{repo}/rulesets?per_page=100"] }
  let(:one) { ["api", "repos/{owner}/{repo}/rulesets/7"] }

  def reply(args, body) = replies[args] = [JSON.generate(body), "", true]

  describe "#named" do
    it "answers the ruleset of that name, in full, and nil when the repository has none" do
      reply(list, [{ "id" => 7 }])
      reply(one, projected.merge("id" => 7))

      expect(rulesets.named("lane-stable")).to include("id" => 7, "name" => "lane-stable")
      expect(rulesets.named("lane-other")).to be_nil
    end

    it "raises with what gh said when it refuses" do
      replies[list] = ["", "HTTP 403: Resource not accessible", false]

      expect { rulesets.named("lane-stable") }.to raise_error(/HTTP 403: Resource not accessible/)
    end
  end

  describe "#apply" do
    it "creates the ruleset when GitHub has none, sending the projection as the body" do
      reply(list, [])
      replies[["api", "--method", "POST", "repos/{owner}/{repo}/rulesets", "--input", "-"]] = ["{}", "", true]

      expect(rulesets.apply(projected)).to eq(:created)
      expect(JSON.parse(calls.last.last)).to eq(projected)
    end

    it "updates the ruleset of that name when GitHub has one" do
      reply(list, [{ "id" => 7 }])
      reply(one, projected.merge("id" => 7))
      replies[["api", "--method", "PUT", "repos/{owner}/{repo}/rulesets/7", "--input", "-"]] = ["{}", "", true]

      expect(rulesets.apply(projected)).to eq(:updated)
    end
  end

  describe "#differences" do
    it "is empty when the live ruleset agrees over what a lane projects, whatever else GitHub adds" do
      live = projected.merge("id" => 7, "source" => "heckslabs/hecks", "current_user_can_bypass" => "never")

      expect(rulesets.differences(projected, live)).to eq([])
    end

    it "says there is no ruleset when GitHub has none" do
      expect(rulesets.differences(projected, nil)).to eq(["lane-stable: GitHub has no such ruleset"])
    end

    it "names each part that differs" do
      live = projected.merge("enforcement" => "disabled", "bypass_actors" => [],
                             "rules" => [{ "type" => "deletion" }],
                             "conditions" => { "ref_name" => { "include" => ["refs/heads/main"] } })

      expect(rulesets.differences(projected, live)).to contain_exactly(
        a_string_matching(/enforcement is "disabled" on GitHub, "active" in the model/),
        a_string_matching(%r{it guards \["refs/heads/main"\] on GitHub}),
        a_string_matching(/bypass actors are \[\] on GitHub/),
        a_string_matching(/rules are \["deletion"\] on GitHub/)
      )
    end
  end
end
