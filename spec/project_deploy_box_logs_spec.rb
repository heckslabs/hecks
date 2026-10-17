require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "hecks/projections/deploy/template_diff"

# Where an AwsBox box's container logs go. By default every service, the proxy and the tunnel included,
# uses Docker's `awslogs` driver into one log group the box stack creates, with a bounded retention and
# a role that may write to that group only; `logs "local"` keeps the rotating `json-file` logs.
RSpec.describe "hecks deploy project — an AwsBox box's logs" do
  LOGS_ROOT = File.expand_path("..", __dir__)
  LOGS_BLUEBOOK = <<~BLUEBOOK.freeze
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
  LOGS_WORLD_HEAD = <<~HEAD.freeze
    Hecks.world "Scratch" do
      deployed_to("AwsBox") do
        region "eu-west-1"
        stack_name "widget-shop"
        containers [{ name: "web", port: 8080 }, { name: "stats", port: 3000 }]
        default_container "web"
  HEAD
  LOGS_AWS_STUB = "#!/bin/bash\necho 123456789012\n".freeze

  def world(*lines)
    body = lines.map { |line| "    #{line}\n" }.join
    "#{LOGS_WORLD_HEAD}#{body}  end\nend\n"
  end

  # Generates the box files for a world; yields them with their directory, or returns the refusal.
  def generate(world_body)
    Dir.mktmpdir do |dir|
      domain = File.join(dir, "scratch_fixture", "bluebook")
      FileUtils.mkdir_p(domain)
      File.write(File.join(domain, "scratch_fixture.bluebook"), LOGS_BLUEBOOK)
      File.write(File.join(domain, "scratch_fixture.world"), world_body)
      out = File.join(dir, "out")
      _stdout, stderr, status = ProjectDeployRunner.run(File.dirname(domain), "--out=#{out}", root: LOGS_ROOT)
      return [nil, stderr] unless status.success?

      [Dir.children(out).to_h { |name| [name, File.read(File.join(out, name))] }, stderr]
    end
  end

  # Runs the generated render-compose.sh with a stubbed `aws` and returns the compose services.
  def compose_services(files)
    Dir.mktmpdir do |dir|
      %w[render-compose.sh services.json].each { |name| File.write(File.join(dir, name), files.fetch(name)) }
      _out, err, status = Open3.capture3(stubbed_aws(dir), "bash", "render-compose.sh", "db.example", "secret", chdir: dir)
      raise err unless status.success?

      JSON.parse(File.read(File.join(dir, "compose.json"))).fetch("services")
    end
  end

  # @return [Hash{String => String}] a PATH whose `aws` answers the account lookup
  def stubbed_aws(dir)
    stub = File.join(dir, "bin", "aws")
    FileUtils.mkdir_p(File.dirname(stub))
    File.write(stub, LOGS_AWS_STUB)
    FileUtils.chmod(0o755, stub)
    { "PATH" => "#{File.dirname(stub)}:#{ENV.fetch("PATH")}" }
  end

  def box_template(files) = Hecks::Projections::Deploy::TemplateDiff::Loader.load(files.fetch("box.yaml"))

  def awslogs_for(stream)
    { "driver" => "awslogs", "options" => { "awslogs-region" => "eu-west-1", "awslogs-group" => "/hecks-widget-shop-box",
                                            "awslogs-create-group" => "false", "tag" => stream } }
  end

  def refusal(*lines) = generate(world(*lines)).last

  let(:files) { generate(world).first }
  let(:tunnelled) { generate(world('tunnel({ to: "stats", token_secret: "widget/tunnel-token" })')).first }

  describe "by default" do
    it "gives every service, the proxy and the tunnel their own awslogs stream in the box's group", :aggregate_failures,
       :process do
      services = compose_services(tunnelled)

      expect(services.keys).to contain_exactly("web", "stats", "caddy", "cloudflared")
      expect(services.to_h { |name, service| [name, service["logging"]] }).to eq(services.keys.to_h { |n| [n, awslogs_for(n)] })
    end

    it "creates the log group in the box stack with a 30 day retention", :aggregate_failures do
      group = box_template(files)["Resources"]["BoxLogGroup"]

      expect(group["Type"]).to eq("AWS::Logs::LogGroup")
      expect(group["Properties"]).to eq("LogGroupName" => "/hecks-widget-shop-box", "RetentionInDays" => 30)
    end

    it "lets the box role write to that group and nothing else", :aggregate_failures do
      policy = box_template(files)["Resources"]["BoxRole"]["Properties"]["Policies"].find { |p| p["PolicyName"] == "write-logs" }
      statement = policy["PolicyDocument"]["Statement"].first

      expect(statement["Action"]).to contain_exactly("logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams")
      expect(statement["Resource"].to_s).to include("BoxLogGroup")
    end

    it "refuses a roll onto a stack that has no log group", :aggregate_failures do
      expect(files["deploy-box.sh"]).to include("--logical-resource-id BoxLogGroup", "exit 44", "SKIP_LOG_GROUP_CHECK")
      expect(files["deploy-box.sh"]).to include("#   44  the box stack has no log group yet")
    end
  end

  describe "log_retention_days" do
    it "is written into the group" do
      group = box_template(generate(world("log_retention_days 365")).first)["Resources"]["BoxLogGroup"]

      expect(group["Properties"]["RetentionInDays"]).to eq(365)
    end

    it "is refused when CloudWatch has no such retention", :aggregate_failures do
      expect(refusal("log_retention_days 45")).to include("log_retention_days").and include("30, 60, 90")
      expect(refusal("log_retention_days 0")).to include("log_retention_days")
    end
  end

  describe 'logs "local"' do
    let(:local) { generate(world('logs "local"')).first }

    it "keeps the rotating json-file logging on every service", :aggregate_failures, :process do
      logging = compose_services(local).values.map { |service| service["logging"] }

      expect(logging.uniq).to eq([{ "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" } }])
    end

    it "adds no log group, no log policy and no roll check", :aggregate_failures do
      expect(local["box.yaml"]).not_to include("Logs::LogGroup", "write-logs")
      expect(local["deploy-box.sh"]).not_to include("BoxLogGroup")
    end

    it "is refused for any other destination" do
      expect(refusal('logs "syslog"')).to include("logs:").and include("cloudwatch")
    end
  end
end
