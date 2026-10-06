require "spec_helper"
require "yaml"

# The workflow that cuts a release holds the one gem-registry secret and can push tags, so its
# shape is pinned: least-privilege permissions, a queue that never cancels a release, the
# agreement check before anything is published, and a secret that reaches only the push.
RSpec.describe ".github/workflows/release.yml" do
  # Each step is skipped when its result already exists.
  STEP_GATES = {
    "Tag the release commit"        => "steps.state.outputs.tagged == 'false'",
    "Build the gem"                 => "steps.state.outputs.gem == 'false'",
    "Push the gem with the API key" => "steps.state.outputs.gem == 'false'",
    "Start the npm publish"         => "steps.state.outputs.npm == 'false'",
    "Create the GitHub Release"     => "steps.state.outputs.release == 'false'"
  }.freeze

  UNLESS_PUSHED = "steps.api_key_push.outputs.pushed != 'true'".freeze

  let(:workflow) { YAML.safe_load(text) }
  let(:steps) { workflow.fetch("jobs").fetch("release").fetch("steps") }

  def text = File.read(File.join(InMemoryDomain::ROOT, ".github/workflows/release.yml"))

  # YAML 1.1 reads the bare key `on` as true.
  def triggers = workflow.fetch("on") { workflow.fetch(true) }

  def code = text.lines.reject { |line| line.strip.start_with?("#") }.join

  def names = steps.filter_map { |step| step["name"] }

  def step_named(name) = steps.find { |step| step["name"] == name }

  it "asks for contents and actions write at the top, and adds the OIDC token to the job only", :aggregate_failures do
    expect(workflow.fetch("permissions")).to eq("contents" => "write", "actions" => "write")
    expect(workflow.fetch("jobs").fetch("release").fetch("permissions"))
      .to eq("contents" => "write", "actions" => "write", "id-token" => "write")
  end

  it "runs after Promote, and by hand with a tag; a push to main starts no release", :aggregate_failures do
    expect(triggers).not_to have_key("push")
    expect(triggers.fetch("workflow_run")).to include("workflows" => ["Promote"], "types" => ["completed"])
    expect(triggers.fetch("workflow_dispatch").fetch("inputs").fetch("tag")).to include("required" => true)
  end

  # Releases come from `stable`: main is integrated state, stable is certified state.
  describe "what it releases" do
    it "reads stable after a promotion" do
      expect(steps.first.fetch("with").fetch("ref")).to include("workflow_run", "'stable'")
    end

    it "releases the commit that set the version, not whatever stable has moved on to" do
      stand = step_named("Stand on the commit that set the version")

      expect(stand.fetch("run")).to include("--first-parent", "lib/hecks/version.rb", "checkout --detach")
    end

    it "refuses a commit that stable does not contain, before it tags or publishes", :aggregate_failures do
      guard = step_named("The release commit is on stable")

      expect(guard.fetch("run")).to include("fetch --quiet origin stable", "merge-base --is-ancestor HEAD FETCH_HEAD", "exit 1")
      expect(names.index("The release commit is on stable")).to be < names.index("The files agree on one version")
      expect(guard).not_to have_key("if")
    end

    it "starts a promotion-triggered release only from a successful Promote run" do
      condition = workflow.fetch("jobs").fetch("detect").fetch("if")

      expect(condition).to include("workflow_run.conclusion == 'success'", "workflow_dispatch")
    end

    # A promotion that releases nothing must not call a package registry.
    it "cuts a release only when detect finds one still to cut", :aggregate_failures do
      jobs = workflow.fetch("jobs")

      expect(jobs.fetch("release")).to include("needs" => "detect", "if" => "needs.detect.outputs.pending == 'true'")
      expect(jobs.fetch("detect").fetch("permissions")).to eq("contents" => "read")
    end

    it "lets detect read GitHub only, never a registry" do
      detect = workflow.fetch("jobs").fetch("detect").to_s

      expect(detect).to include("gh release view").and(satisfy { |text| !text.include?("rubygems") && !text.include?("npmjs") })
    end
  end

  it "queues releases and never cancels one that is running" do
    expect(workflow.fetch("concurrency")).to include("cancel-in-progress" => false)
  end

  it "has a timeout" do
    expect(workflow.fetch("jobs").fetch("release")).to include("timeout-minutes")
  end

  it "checks that the four version sources agree before it tags or publishes", :aggregate_failures do
    check = step_named("The files agree on one version")

    expect(check.fetch("run")).to include("lib/hecks/version.rb", "packages/hecks-client/package.json",
                                          "rust/host/HECKS_RELEASE", "CHANGELOG.md")
    expect(names.index("The files agree on one version")).to be < names.index("Tag the release commit")
    expect(names.index("Tag the release commit")).to be < names.index("Push the gem with the API key")
  end

  it "hands the gem key to the push step only", :aggregate_failures do
    holders = steps.select { |step| step.to_s.include?("secrets.RUBYGEMS_API_KEY") }

    expect(holders.map { |step| step["name"] }).to eq(["Push the gem with the API key"])
    expect(holders.first.fetch("env")).to include("GEM_HOST_API_KEY" => "${{ secrets.RUBYGEMS_API_KEY }}")
    expect(code).not_to match(/echo[^\n]*GEM_HOST_API_KEY/)
  end

  it "skips each step whose result already exists" do
    gated = steps.select { |step| step["name"] && step["if"] }.to_h { |step| [step["name"], step["if"]] }

    expect(gated.slice(*STEP_GATES.keys)).to eq(STEP_GATES)
  end

  it "starts the npm publish by dispatch, since a GITHUB_TOKEN tag push starts nothing" do
    start = step_named("Start the npm publish")

    expect(start.fetch("run")).to include("gh workflow run publish-client.yml")
  end

  it "creates the release from the CHANGELOG section and marks it latest" do
    release = step_named("Create the GitHub Release")

    expect(release.fetch("run")).to include("CHANGELOG.md", "--notes-file", "--latest", "--verify-tag")
  end

  describe "the gem push" do
    def api_push = step_named("Push the gem with the API key")

    def oidc_push = step_named("Push the gem with trusted publishing")

    def configure = step_named("Configure RubyGems trusted publishing")

    it "retries the API-key push with backoff and does not retry a refused key" do
      expect(api_push.fetch("run")).to include("for attempt in", "sleep", "401|403")
    end

    it "falls back to trusted publishing when the API-key push did not land", :aggregate_failures do
      expect(api_push.fetch("id")).to eq("api_key_push")
      expect(configure.fetch("uses")).to match(%r{\Arubygems/configure-rubygems-credentials@\h{40}})
      expect(configure.fetch("if")).to include(UNLESS_PUSHED)
      expect(oidc_push.fetch("if")).to include(UNLESS_PUSHED)
    end

    it "configures and uses trusted publishing only after the API-key push", :aggregate_failures do
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

    it "checks the version is listed before the npm publish and the release", :aggregate_failures do
      expect(names.index("The gem is listed")).to be < names.index("Start the npm publish")
      expect(names.index("The gem is listed")).to be < names.index("Create the GitHub Release")
    end
  end
end
