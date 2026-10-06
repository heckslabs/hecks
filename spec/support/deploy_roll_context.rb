require "json"
require_relative "box_hosting_stubs"

# The tags, platform values and environments the roll specs share.
ROLL_TAGS = "tags=website=website-old cms=cms-old".freeze
PLATFORM_TAGS = { "website" => "website-old", "cms" => "cms-old", "domain" => "domain-old" }.freeze
PARAMETERS = { "WebsiteImageTag" => "website-old", "CmsImageTag" => "cms-keep",
               "EngineImageTag" => "domain-old", "Other" => "x" }.freeze
VERIFIED_STATE = { "status" => "verified", "tag" => "cms-old", "taskdef" => "widget-platform:7" }.freeze
REDEPLOY_ENV = { "STUB_ECR_HAS_TAG" => "1", "STUB_NO_UPDATES" => "1" }.freeze
ROLL_NO_DATABASE_ENV = { "FAKE_NO_DATABASE" => "1", "EXISTING_TAG" => "cms-old", "STUB_ECR_HAS_TAG" => "1" }.freeze

# What `hecks_deploy_roll_spec.rb` and `hecks_deploy_roll_scripts_spec.rb` share: the Hecks domain
# booted once per file, the goldens a stand-in toolchain is built from, and the helpers that run a
# roll verb against it and read its state.
RSpec.shared_context "with the deploy roll stand-ins" do
  let(:taskdef_golden)  { File.join(__dir__, "..", "fixtures", "deploy_box_golden", "hosting_taskdef") }
  let(:services_golden) { File.join(__dir__, "..", "fixtures", "deploy_box_golden", "hosting_services") }
  let(:registry)        { BoxHostingStubs::REGISTRY }

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  # Runs each example of the group with a stand-in toolchain built from the golden named by the `let`.
  def self.with_stub_runner(golden, **options)
    around do |example|
      BoxHostingStubs.with_runner(send(golden), **options) do |runner|
        @runner = runner
        example.run
      end
    end
  end

  attr_reader :runner

  # The stand-in programs first on PATH, as the generated scripts find them.
  def stub_env(env = {})
    { "PATH" => "#{File.join(runner.dir, "bin")}:#{ENV.fetch("PATH")}", "STUB_DIR" => runner.dir,
      "SETTLE_CHECK_INTERVAL_SECS" => "1", "SETTLE_TIMEOUT_SECS" => "3", "SSM_POLL_SECS" => "0.1" }.merge(env)
  end

  def deploy_call(verb, target, *argv)
    Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks", argv: ["deploy", verb, target, *argv, "--wait"])
  end

  # Runs the verb against the runner's scripts with the stand-in programs on PATH.
  def command(verb, *argv, env: {})
    settings = stub_env(env)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    out, status = deploy_call(verb, File.join(runner.dir, "scripts"), *argv)
    [JSON.parse(out), status]
  ensure
    settings&.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def settled(names: %w[website cms])
    up = (names + ["caddy"]).map { |name| "#{name} Up 3 minutes" }
    images = names.to_h { |name| [name, "#{registry}/widget-#{name}:#{name}-old"] }
    runner.box_report(compose: images, containers: up.join("\n"))
  end

  def settled_and_pinned
    settled(names: %w[website cms domain])
    runner.pin_task_definition("widget-platform:7", PLATFORM_TAGS)
  end

  # Rolls the cms service to a tag that is already in ECR; `env` adds to the stand-in environment.
  def roll_cms_existing(**env)
    command("service_roll.run", "service=cms", "existing_tag=cms-old", env: { "STUB_ECR_HAS_TAG" => "1" }.merge(env))
  end

  # The status of the SmokeRun that the roll's policy requested under the roll's own run key.
  def smoke_status(json)
    out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                        argv: ["deploy", "smoke_run.verdict", "run=#{json.fetch("run")}"])
    JSON.parse(out).first&.fetch("status")
  end

  def smoke_dispatched? = runner.calls.any? { |call| call.start_with?("gh workflow run") }

  # The named fields of a roll's state: its status as is, every other field as its value.
  def state_of(json, *fields)
    state = json.fetch("state")
    fields.to_h { |field| [field, field == "status" ? state[field] : state.dig(field, "value")] }
  end

  def refusal_of(json) = json.dig("state", "refusal", "value")
end
