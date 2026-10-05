require "spec_helper"
require "yaml"

# The workflow that cuts a release holds the one gem-registry secret and can push tags, so its
# shape is pinned: least-privilege permissions, a queue that never cancels a release, the
# agreement check before anything is published, and a secret that reaches only the push.
RSpec.describe ".github/workflows/release.yml" do
  let(:path) { File.join(InMemoryDomain::ROOT, ".github/workflows/release.yml") }
  let(:text) { File.read(path) }
  let(:workflow) { YAML.safe_load(text) }
  # YAML 1.1 reads the bare key `on` as true.
  let(:triggers) { workflow.fetch("on") { workflow.fetch(true) } }
  let(:steps) { workflow.fetch("jobs").fetch("release").fetch("steps") }
  let(:code) { text.lines.reject { |line| line.strip.start_with?("#") }.join }

  it "asks for contents and actions write at the top, and adds the OIDC token to the job only" do
    expect(workflow.fetch("permissions")).to eq("contents" => "write", "actions" => "write")
    expect(workflow.fetch("jobs").fetch("release").fetch("permissions"))
      .to eq("contents" => "write", "actions" => "write", "id-token" => "write")
  end

  it "runs when main changes the version file, and by hand with a tag" do
    expect(triggers.fetch("push")).to include("branches" => ["main"], "paths" => ["lib/hecks/version.rb"])
    expect(triggers.fetch("workflow_dispatch").fetch("inputs").fetch("tag")).to include("required" => true)
  end

  it "queues releases and never cancels one that is running" do
    expect(workflow.fetch("concurrency")).to include("cancel-in-progress" => false)
  end

  it "has a timeout" do
    expect(workflow.fetch("jobs").fetch("release")).to include("timeout-minutes")
  end

  it "checks that the four version sources agree before it tags or publishes" do
    names = steps.filter_map { |step| step["name"] }
    check = steps.find { |step| step["name"] == "The files agree on one version" }

    expect(check.fetch("run")).to include("lib/hecks/version.rb", "packages/hecks-client/package.json",
                                          "rust/host/HECKS_RELEASE", "CHANGELOG.md")
    expect(names.index("The files agree on one version")).to be < names.index("Tag the release commit")
    expect(names.index("Tag the release commit")).to be < names.index("Push the gem with the API key")
  end

  it "hands the gem key to the push step only" do
    holders = steps.select { |step| step.to_s.include?("secrets.RUBYGEMS_API_KEY") }

    expect(holders.map { |step| step["name"] }).to eq(["Push the gem with the API key"])
    expect(holders.first.fetch("env")).to include("GEM_HOST_API_KEY" => "${{ secrets.RUBYGEMS_API_KEY }}")
    expect(code).not_to match(/echo[^\n]*GEM_HOST_API_KEY/)
  end

  it "skips each step whose result already exists" do
    gated = steps.select { |step| step["name"] && step["if"] }.to_h { |step| [step["name"], step["if"]] }

    expect(gated.fetch("Tag the release commit")).to eq("steps.state.outputs.tagged == 'false'")
    expect(gated.fetch("Build the gem")).to eq("steps.state.outputs.gem == 'false'")
    expect(gated.fetch("Push the gem with the API key")).to eq("steps.state.outputs.gem == 'false'")
    expect(gated.fetch("Start the npm publish")).to eq("steps.state.outputs.npm == 'false'")
    expect(gated.fetch("Create the GitHub Release")).to eq("steps.state.outputs.release == 'false'")
  end

  it "starts the npm publish by dispatch, since a GITHUB_TOKEN tag push starts nothing" do
    start = steps.find { |step| step["name"] == "Start the npm publish" }

    expect(start.fetch("run")).to include("gh workflow run publish-client.yml")
  end

  it "creates the release from the CHANGELOG section and marks it latest" do
    release = steps.find { |step| step["name"] == "Create the GitHub Release" }

    expect(release.fetch("run")).to include("CHANGELOG.md", "--notes-file", "--latest", "--verify-tag")
  end

  describe "the gem push" do
    let(:api_push) { steps.find { |step| step["name"] == "Push the gem with the API key" } }
    let(:oidc_push) { steps.find { |step| step["name"] == "Push the gem with trusted publishing" } }
    let(:configure) { steps.find { |step| step["name"] == "Configure RubyGems trusted publishing" } }
    let(:names) { steps.filter_map { |step| step["name"] } }

    it "retries the API-key push with backoff and does not retry a refused key" do
      expect(api_push.fetch("run")).to include("for attempt in", "sleep", "401|403")
    end

    it "falls back to trusted publishing when the API-key push did not land" do
      unless_pushed = "steps.api_key_push.outputs.pushed != 'true'"

      expect(api_push.fetch("id")).to eq("api_key_push")
      expect(configure.fetch("uses")).to match(%r{\Arubygems/configure-rubygems-credentials@\h{40}})
      expect(configure.fetch("if")).to include(unless_pushed)
      expect(oidc_push.fetch("if")).to include(unless_pushed)
      expect(names.index("Push the gem with the API key")).to be < names.index("Configure RubyGems trusted publishing")
      expect(names.index("Push the gem with trusted publishing")).to be < names.index("The gem is listed")
    end

    it "treats an already-published version as done on both paths" do
      [api_push, oidc_push].each do |step|
        expect(step.fetch("run")).to include("repushing of gem versions is not allowed")
      end
    end

    it "names what to configure when both paths fail, and sends the next step to a re-run" do
      expect(oidc_push.fetch("run")).to include("::error::", "RUBYGEMS_API_KEY", "Trusted publishers", "heckslabs",
                                                "release.yml", "gh workflow run release.yml")
    end

    it "does not give the secret to the OIDC path" do
      expect(oidc_push.to_s).not_to include("secrets.")
    end

    it "checks the version is listed before the npm publish and the release" do
      expect(names.index("The gem is listed")).to be < names.index("Start the npm publish")
      expect(names.index("The gem is listed")).to be < names.index("Create the GitHub Release")
    end
  end
end
