require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"

# `hecks deploy project environment==<name>` layers `bluebook/environments/<name>.world`
# over the base `.world`. Runs the script against a throwaway domain and reads its output.
RSpec.describe "hecks deploy project environment=", :io do
  ENV_FIXTURE_BASENAME = "project_deploy_environment_spec_fixture".freeze

  ENV_FIXTURE_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "EnvDeploy" do
      aggregate "Thing" do
        identified_by :name
        attribute :name, ThingName
        value_object "ThingName" do
          attribute :value, String
          invariant("named") { !value.to_s.empty? }
        end
        command "Create" do
          attribute :name, ThingName
          sets :name
          emits "ThingCreated"
        end
      end
    end
  BLUEBOOK

  ENV_FIXTURE_WORLD = <<~WORLD.freeze
    Hecks.world "EnvDeploy" do
      deployed_to("AwsLambda") do
        region "us-east-1"
      end
    end
  WORLD

  ENV_FIXTURE_PRODUCTION_WORLD = <<~WORLD.freeze
    Hecks.world "EnvDeploy" do
      deployed_to("AwsLambda") do
        region "us-east-1"
        stack_prefix "pinned"
      end
    end
  WORLD

  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  def root = File.expand_path("..", __dir__)

  def write_fixture(dir)
    bluebook_dir = File.join(dir, ENV_FIXTURE_BASENAME, "bluebook")
    FileUtils.mkdir_p(File.join(bluebook_dir, "environments"))
    File.write(File.join(bluebook_dir, "#{ENV_FIXTURE_BASENAME}.bluebook"), ENV_FIXTURE_BLUEBOOK)
    File.write(File.join(bluebook_dir, "#{ENV_FIXTURE_BASENAME}.world"), ENV_FIXTURE_WORLD)
    File.write(File.join(bluebook_dir, "environments", "production.world"), ENV_FIXTURE_PRODUCTION_WORLD)
    File.join(dir, ENV_FIXTURE_BASENAME)
  end

  def run_project_deploy(domain_dir, *flags)
    ProjectDeployRunner.run(domain_dir, *flags, root: root)
  end

  # The template.yaml `hecks deploy project` writes into the `label` directory under the flags.
  def template_from(domain_dir, label, *flags)
    out = File.join(dir, label)
    _out, err, status = run_project_deploy(domain_dir, *flags, "--out=#{out}")
    status.success? or raise "hecks deploy project #{flags.join(" ")} failed: #{err}"

    File.read(File.join(out, "template.yaml"))
  end

  it "names the stack from the overlay when --environment is given, and from the base when not", :aggregate_failures do
    domain_dir = write_fixture(dir)

    expect(template_from(domain_dir, "base")).to include("FunctionName: hecks-#{ENV_FIXTURE_BASENAME}")
    expect(template_from(domain_dir, "overlay", "--environment=production"))
      .to include("FunctionName: pinned-#{ENV_FIXTURE_BASENAME}")
  end

  it "refuses an --environment with no overlay, rather than silently naming a different stack", :aggregate_failures do
    domain_dir = write_fixture(dir)

    _out, err, status = run_project_deploy(domain_dir, "--environment=staging", "--out=#{File.join(dir, "out")}")

    expect(status).not_to be_success
    expect(err).to include("environments/staging.world does not exist")
    expect(File).not_to exist(File.join(dir, "out"))
  end
end
