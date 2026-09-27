require "spec_helper"
require "yaml"

# The workflow that publishes @hecks/client uses npm trusted publishing: the job
# authenticates with an OIDC identity token, so it needs `id-token: write`, and it
# must not hold an npm token or any secret. This pins that shape, so an edit that
# reaches for a stored token (which would defeat the point) or drops the
# permission (which would break the publish) fails here.
RSpec.describe ".github/workflows/publish-client.yml" do
  let(:path) { File.join(InMemoryDomain::ROOT, ".github/workflows/publish-client.yml") }
  let(:text) { File.read(path) }
  let(:workflow) { YAML.safe_load(text) }
  # YAML 1.1 reads the bare key `on` as true.
  let(:triggers) { workflow.fetch("on") { workflow.fetch(true) } }
  let(:steps) { workflow.fetch("jobs").fetch("publish").fetch("steps") }
  let(:code) { text.lines.reject { |line| line.strip.start_with?("#") }.join }

  it "grants an identity token and read-only contents, and nothing else" do
    expect(workflow.fetch("permissions")).to eq("contents" => "read", "id-token" => "write")
  end

  it "runs when a v* tag is pushed, and by hand with a tag input" do
    expect(triggers.fetch("push").fetch("tags")).to eq(["v*"])
    expect(triggers.fetch("workflow_dispatch").fetch("inputs").fetch("tag")).to include("required" => true)
  end

  it "publishes with provenance and public access" do
    publish = steps.find { |step| step["name"] == "Publish" }

    expect(publish.fetch("run")).to eq("npm publish --access public --provenance")
    expect(publish.fetch("working-directory")).to eq("packages/hecks-client")
  end

  it "holds no secret and no npm token" do
    expect(code).not_to match(/secrets\./i)
    expect(code).not_to match(/NODE_AUTH_TOKEN|NPM_TOKEN|_authToken|npm_[A-Za-z0-9]{20,}/)
  end

  it "sets up Node 24 against the npm registry, with an npm new enough for trusted publishing" do
    setup = steps.find { |step| step["uses"].to_s.start_with?("actions/setup-node@") }
    npm = steps.find { |step| step["name"] == "Use a current npm" }

    expect(setup.fetch("with")).to include("node-version" => "24", "registry-url" => "https://registry.npmjs.org")
    expect(npm.fetch("run")).to include("npm@^11.5.1")
  end

  it "refuses a tag that does not name the package and gem version" do
    guard = steps.find { |step| step["name"] == "The tag names this release" }

    expect(guard.fetch("run")).to include("packages/hecks-client/package.json", "lib/hecks/version.rb", "exit 1")
  end

  it "skips every publishing step when npm already has the version" do
    gated = steps.select { |step| step["if"] }

    expect(gated.map { |step| step["if"] }.uniq).to eq(["steps.state.outputs.published == 'false'"])
    expect(gated.filter_map { |step| step["name"] }).to include("Install", "Build and test", "Publish")
  end

  it "installs and tests before it publishes" do
    names = steps.filter_map { |step| step["name"] }

    expect(names.index("Install")).to be < names.index("Build and test")
    expect(names.index("Build and test")).to be < names.index("Publish")
  end
end
