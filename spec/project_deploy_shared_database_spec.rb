require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "hecks/projections/deploy/template_diff"

# `hecks deploy project` for a domain that declares `deployed_to("AwsSharedDatabase")`: the one RDS
# instance that several sites each keep a database on (ADR 0092).
#
# The golden files in `spec/fixtures/deploy_shared_database_golden/default/` are generator output. To
# regenerate after a deliberate change, write the world below into `<dir>/bluebook/scratch_fixture.world`
# beside `scratch_fixture.bluebook`, run `hecks deploy project <dir> --out=<golden dir>` and review the
# diff; never edit a golden file by hand.
RSpec.describe "hecks deploy project, a deployed_to(\"AwsSharedDatabase\") stack", :io do
  SHARED_ROOT_DIR = File.expand_path("..", __dir__)
  SHARED_GOLDEN_DIR = File.join(__dir__, "fixtures", "deploy_shared_database_golden", "default")
  SHARED_FIXTURE_NAME = "scratch_fixture".freeze

  # The default world is generated once for the examples that only read it.
  module SharedGeneratedWorlds
    def self.fetch(key) = (@worlds ||= {})[key] ||= yield
  end

  SHARED_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Scratch" do
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

  DEFAULT_WORLD = <<~WORLD.freeze
    Hecks.world "Scratch" do
      deployed_to("AwsSharedDatabase") do
        region "us-east-1"
        stack_name "hecks-platform-rds"
      end
    end
  WORLD

  # World source whose `deployed_to("AwsSharedDatabase")` block is `region` plus the given lines.
  def world_source(*lines)
    body = lines.map { |line| "    #{line}\n" }.join
    "Hecks.world \"Scratch\" do\n  deployed_to(\"AwsSharedDatabase\") do\n    region \"us-east-1\"\n#{body}  end\nend\n"
  end

  # Writes the scratch domain into a temporary directory and runs the generator; returns the generated
  # files by name (nil when it refused) and its stderr.
  def generate(world_body)
    Dir.mktmpdir do |dir|
      domain = File.join(dir, SHARED_FIXTURE_NAME)
      FileUtils.mkdir_p(File.join(domain, "bluebook"))
      File.write(File.join(domain, "bluebook", "#{SHARED_FIXTURE_NAME}.bluebook"), SHARED_BLUEBOOK)
      File.write(File.join(domain, "bluebook", "#{SHARED_FIXTURE_NAME}.world"), world_body)
      out = File.join(dir, "out")
      _stdout, stderr, status = ProjectDeployRunner.run(domain, "--out=#{out}", root: SHARED_ROOT_DIR)
      [status.success? ? Dir.children(out).to_h { |name| [name, File.read(File.join(out, name))] } : nil, stderr]
    end
  end

  def template_of(text) = Hecks::Projections::Deploy::TemplateDiff::Loader.load(text)

  let(:files) { SharedGeneratedWorlds.fetch(:default) { generate(DEFAULT_WORLD).first } }

  it "renders its golden files", :aggregate_failures do
    golden = Dir.children(SHARED_GOLDEN_DIR).sort.to_h { |name| [name, File.read(File.join(SHARED_GOLDEN_DIR, name))] }

    expect(files.keys).to match_array(golden.keys)
    expect(golden.reject { |name, text| files[name] == text }.keys).to eq([])
  end

  it "writes a stack that loads as CloudFormation" do
    expect { template_of(files["rds.yaml"]) }.not_to raise_error
  end

  it "writes the instance and nothing a single site would own", :aggregate_failures do
    expect(files.keys).to match_array(%w[Makefile README.md rds.yaml])
    expect(files["rds.yaml"]).not_to include("DBName", "DatabaseName")
  end

  it "exports what a site's box and its provisioning read", :aggregate_failures do
    outputs = template_of(files["rds.yaml"])["Outputs"].keys

    expect(outputs).to include("DbEndpoint", "DbSecretArn", "DbSecurityGroupId", "AlertTopicArn")
  end

  it "leaves the security group's rules to the sites, and gives the bastion a rule of its own", :aggregate_failures do
    resources = template_of(files["rds.yaml"])["Resources"]

    expect(resources["DbSecurityGroup"]["Properties"]).not_to have_key("SecurityGroupIngress")
    expect(resources["BastionIngress"]).to include("Type" => "AWS::EC2::SecurityGroupIngress", "Condition" => "HasBastion")
  end

  it "is a real instance by default: deletion protection and a snapshot on delete", :aggregate_failures do
    database = template_of(files["rds.yaml"])["Resources"]["Database"]

    expect(database["DeletionPolicy"]).to eq("Fn::If" => %w[IsRehearsal Delete Snapshot])
    expect(files["rds.yaml"]).to include("Default: \"false\"")
  end

  it "names the stack exactly as the world gives it, for every site to refer to", :aggregate_failures do
    expect(files["Makefile"]).to include("STACK = hecks-platform-rds")
    expect(files["README.md"]).to include('shared_database "hecks-platform-rds"')
  end

  it "takes the instance's size from the world" do
    files, = generate(world_source('stack_name "hecks-platform-rds"', 'database_class "db.t4g.large"', "storage_gb 100",
                                   'engine_version "16.4"', "backup_days 14"))

    expect(files["rds.yaml"]).to include("Default: db.t4g.large", "Default: 100", 'Default: "16.4"', "Default: 14")
  end

  describe "a world that is wrong" do
    it "refuses a world with no stack name, which no site could then refer to", :aggregate_failures do
      files, stderr = generate(world_source)

      expect(files).to be_nil
      expect(stderr).to include("stack_name")
    end

    it "refuses a stack name that could carry shell syntax", :aggregate_failures do
      files, stderr = generate(world_source('stack_name "x; rm -rf /"'))

      expect(files).to be_nil
      expect(stderr).to include("stack_name")
    end

    it "refuses storage below the floor, naming the world's block", :aggregate_failures do
      files, stderr = generate(world_source('stack_name "hecks-platform-rds"', "storage_gb 5"))

      expect(files).to be_nil
      expect(stderr).to include('deployed_to("AwsSharedDatabase") is invalid').and include("storage is at least 20 GB")
    end

    it "refuses a retention outside what RDS allows", :aggregate_failures do
      files, stderr = generate(world_source('stack_name "hecks-platform-rds"', "backup_days 90"))

      expect(files).to be_nil
      expect(stderr).to include("backup_days")
    end
  end
end
