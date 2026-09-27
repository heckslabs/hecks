require "yaml"

# Hecks::Projections::Deploy::Smoke adds the smoke harness and its workflow to a
# deploy artifact, only for a domain that opted in with `smoke true`.
RSpec.describe Hecks::Projections::Deploy::Smoke do
  let(:opted_in) do
    {
      region:          "us-east-1",
      smoke:           true,
      smoke_role_arn:  "arn:aws:iam::123456789012:role/example-smoke",
      smoke_secret_id: "example-stack/session-secret",
      smoke_site_url:  "https://example.org"
    }
  end

  def workflow(settings = opted_in)
    described_class.files(settings, stack_name: "example").fetch("smoke/workflow.yml")
  end

  def steps(text)
    YAML.safe_load(text).fetch("jobs").fetch("smoke").fetch("steps")
  end

  it "adds nothing unless the domain opted in" do
    expect(described_class.files({ region: "us-east-1" }, stack_name: "example")).to eq({})
    expect(described_class.files(opted_in.merge(smoke: false), stack_name: "example")).to eq({})
  end

  it "does not require the smoke settings when the domain has not opted in" do
    expect { described_class.files({}, stack_name: "example") }.not_to raise_error
  end

  it "emits the harness unchanged, beside the rendered workflow" do
    files = described_class.files(opted_in, stack_name: "example")

    expect(files.keys).to eq(%w[smoke/harness.js smoke/workflow.yml])
    expect(files["smoke/harness.js"]).to eq(File.read(File.join(described_class::TEMPLATES, "harness.js")))
  end

  it "renders a workflow that trades the OIDC token for the role and reads one secret" do
    parsed = YAML.safe_load(workflow)

    expect(parsed["name"]).to eq("example smoke test")
    expect(parsed["permissions"]).to include("id-token" => "write", "contents" => "read")
    expect(parsed[true]["schedule"]).to eq([{ "cron" => "*/15 * * * *" }])

    aws = steps(workflow).find { |step| step["uses"].to_s.start_with?("aws-actions/configure-aws-credentials") }
    expect(aws["with"]).to eq("role-to-assume" => "arn:aws:iam::123456789012:role/example-smoke", "aws-region" => "us-east-1")
  end

  it "runs the harness in safe mode against the site, with the secret in the configured variable" do
    run = steps(workflow).last

    expect(run["env"]).to include("SMOKE_MODE" => "safe", "SMOKE_SITE_URL" => "https://example.org")
    expect(run["env"]["SESSION_SECRET"]).to eq("${{ steps.secret.outputs.value }}")
    expect(run["run"]).to eq("node smoke/harness.js smoke/config.js")
  end

  it "leaves no placeholder behind, and no setup step when none was asked for" do
    expect(workflow).not_to include("@@")
    expect(steps(workflow).map { |step| step["name"] }).not_to include("Set up the smoke run")
  end

  it "takes a secret field, a variable name, a schedule, paths and a setup command" do
    text = workflow(opted_in.merge(smoke_secret_field: "session_secret", smoke_secret_env: "APP_SECRET",
                                   smoke_schedule: "0 * * * *", smoke_harness: "ci/harness.js",
                                   smoke_config: "ci/config.js", smoke_setup: "npm ci --no-audit"))
    parsed_steps = steps(text)
    setup = parsed_steps.find { |step| step["name"] == "Set up the smoke run" }
    secret = parsed_steps.find { |step| step["id"] == "secret" }

    expect(YAML.safe_load(text)[true]["schedule"]).to eq([{ "cron" => "0 * * * *" }])
    expect(parsed_steps.index(setup)).to be < parsed_steps.index(secret)
    expect(setup["run"]).to eq("npm ci --no-audit")
    expect(secret["run"]).to include("JSON.parse(require(\"fs\").readFileSync(0)).session_secret")
    expect(parsed_steps.last["env"]).to have_key("APP_SECRET")
    expect(parsed_steps.last["run"]).to eq("node ci/harness.js ci/config.js")
  end

  it "reads the secret as plain text when no field is named" do
    secret_step = steps(workflow).find { |step| step["id"] == "secret" }

    expect(secret_step["run"]).not_to include("node -e")
    expect(secret_step["run"]).to include("--secret-id 'example-stack/session-secret'")
  end

  it "names every missing required setting" do
    expect { described_class.files({ smoke: true }, stack_name: "example") }
      .to raise_error(ArgumentError, /smoke_role_arn, smoke_secret_id, smoke_site_url, region/)
  end

  {
    smoke_role_arn:   "arn:aws:iam::12:role/short",
    smoke_secret_id:  "id with spaces",
    smoke_site_url:   "https://example.org'\nrun: evil",
    smoke_schedule:   "* * *",
    smoke_secret_env: "lower_case",
    smoke_harness:    "a b/harness.js",
    smoke_setup:      "one\ntwo"
  }.each do |setting, value|
    it "refuses a #{setting} that would not survive being spliced into the workflow" do
      expect { workflow(opted_in.merge(setting => value)) }
        .to raise_error(ArgumentError, /#{setting} .* is not a value the smoke workflow can carry/)
    end
  end

  it "quotes a setup command that contains a single quote" do
    text = workflow(opted_in.merge(smoke_setup: "echo 'hi'"))

    expect(steps(text).find { |step| step["name"] == "Set up the smoke run" }["run"]).to eq("echo 'hi'")
  end
end
