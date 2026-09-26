require "tmpdir"
require "fileutils"
require "open3"

# `bin/project_deploy --environment=<name>` layers
# `<domain>/bluebook/environments/<name>.world` over the base `.world`,
# so a domain's base file stays generic and a real live stack's naming
# lives in the overlay that targets it. Structural, like
# project_deploy_out_spec.rb: runs the script as a subprocess against a
# throwaway domain and reads back what it wrote.
RSpec.describe "bin/project_deploy --environment", :io do
  ENV_FIXTURE_BASENAME = "project_deploy_environment_spec_fixture".freeze

  def root = File.expand_path("..", __dir__)

  def write_fixture(dir)
    bluebook_dir = File.join(dir, ENV_FIXTURE_BASENAME, "bluebook")
    FileUtils.mkdir_p(File.join(bluebook_dir, "environments"))

    File.write(File.join(bluebook_dir, "#{ENV_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
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

    File.write(File.join(bluebook_dir, "#{ENV_FIXTURE_BASENAME}.world"), <<~WORLD)
      Hecks.world "EnvDeploy" do
        deployed_to("AwsLambda") do
          region "us-east-1"
        end
      end
    WORLD

    File.write(File.join(bluebook_dir, "environments", "production.world"), <<~WORLD)
      Hecks.world "EnvDeploy" do
        deployed_to("AwsLambda") do
          region "us-east-1"
          stack_prefix "pinned"
        end
      end
    WORLD

    File.join(dir, ENV_FIXTURE_BASENAME)
  end

  def run_project_deploy(domain_dir, *flags)
    Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir, *flags)
  end

  it "names the stack from the overlay when --environment is given, and from the base when not" do
    Dir.mktmpdir do |dir|
      domain_dir = write_fixture(dir)
      base_out = File.join(dir, "base")
      overlay_out = File.join(dir, "overlay")

      _out, err, status = run_project_deploy(domain_dir, "--out=#{base_out}")
      status.success? or raise "bin/project_deploy failed: #{err}"
      _out, err, status = run_project_deploy(domain_dir, "--environment=production", "--out=#{overlay_out}")
      status.success? or raise "bin/project_deploy --environment failed: #{err}"

      expect(File.read(File.join(base_out, "template.yaml"))).to include("FunctionName: hecks-#{ENV_FIXTURE_BASENAME}")
      expect(File.read(File.join(overlay_out, "template.yaml"))).to include("FunctionName: pinned-#{ENV_FIXTURE_BASENAME}")
    end
  end

  it "refuses an --environment with no overlay, rather than silently naming a different stack" do
    Dir.mktmpdir do |dir|
      domain_dir = write_fixture(dir)

      _out, err, status = run_project_deploy(domain_dir, "--environment=staging", "--out=#{File.join(dir, 'out')}")

      expect(status).not_to be_success
      expect(err).to include("environments/staging.world does not exist")
      expect(File).not_to exist(File.join(dir, "out"))
    end
  end
end
