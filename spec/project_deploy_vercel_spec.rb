require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "json"

# `hecks deploy project` for a domain that declares `deployed_to("Vercel")`: the domain's host as
# one Vercel function. The promises: the defaults render a working `vercel.json`, a full world
# renders its crons and variables, and a world cannot splice shell or JSON into the output.
RSpec.describe "hecks deploy project — a deployed_to(\"Vercel\") function", :io do
  VERCEL_ROOT_DIR = File.expand_path("..", __dir__)
  VERCEL_FIXTURE = "scratch_fixture".freeze

  VERCEL_BLUEBOOK = <<~BLUEBOOK.freeze
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

  def world_source(*lines)
    body = lines.map { |line| "    #{line}\n" }.join
    "Hecks.world \"Scratch\" do\n  deployed_to(\"Vercel\") do\n#{body}  end\nend\n"
  end

  # @return [Array(Hash{String => String}, String)] the generated files (nil on a refusal) and stderr
  def generate(world_body)
    Dir.mktmpdir do |dir|
      domain = File.join(dir, VERCEL_FIXTURE)
      FileUtils.mkdir_p(File.join(domain, "bluebook"))
      File.write(File.join(domain, "bluebook", "#{VERCEL_FIXTURE}.bluebook"), VERCEL_BLUEBOOK)
      File.write(File.join(domain, "bluebook", "#{VERCEL_FIXTURE}.world"), world_body)
      out = File.join(dir, "out")
      _stdout, stderr, status = ProjectDeployRunner.run(domain, "--out=#{out}", root: VERCEL_ROOT_DIR)
      return [nil, stderr] unless status.success?

      [Dir.glob("*", File::FNM_DOTMATCH, base: out).reject { |n| n.start_with?("..") || n == "." }
          .to_h { |name| [name, File.read(File.join(out, name))] }, stderr]
    end
  end

  it "renders the function, its rewrite and the deploy scripts from defaults", :aggregate_failures do
    files, = generate(world_source)

    expect(files.keys).to match_array(%w[vercel.json .vercelignore deploy-vercel.sh Makefile])
    config = JSON.parse(files["vercel.json"])
    expect(config["functions"]).to eq("api/host.rs" => { "memory" => 1024, "maxDuration" => 30 })
    expect(config["regions"]).to eq(["iad1"])
    expect(config["rewrites"]).to eq([{ "source" => "/(.*)", "destination" => "/api/host" }])
    expect(config).not_to have_key("crons")
    expect(files["deploy-vercel.sh"]).to include("DATABASE_URL:?DATABASE_URL must be set")
    expect(files["deploy-vercel.sh"]).to include("vercel deploy --prod --yes")
  end

  it "renders crons, extra variables, a scope and sizes from a full world", :aggregate_failures do
    files, = generate(world_source('region "fra1"', "memory 2048", "max_duration 60", 'scope "acme"',
                                   'env ["SESSION_SECRET"]', 'crons [{ path: "/cron/tick", schedule: "*/5 * * * *" }]'))

    config = JSON.parse(files["vercel.json"])
    expect(config["regions"]).to eq(["fra1"])
    expect(config["functions"]["api/host.rs"]).to eq("memory" => 2048, "maxDuration" => 60)
    expect(config["crons"]).to eq([{ "path" => "/cron/tick", "schedule" => "*/5 * * * *" }])
    expect(files["deploy-vercel.sh"]).to include("SESSION_SECRET", "--scope acme")
    expect(files["deploy-vercel.sh"]).not_to match(/\bSESSION_SECRET=/)
  end

  it "refuses values the bluebook or the settings check, naming the world file", :aggregate_failures do
    [
      ['region "us-east-1"', /region is a Vercel id/],
      ["memory 64", /memory is at least 128 MB/],
      ["max_duration 900", /duration is at most 800 seconds/],
      ['env ["x; rm -rf /"]', /env .* is not allowed/],
      ['crons [{ path: "/a", schedule: "* *" }]', /cron_schedule .* is not allowed/]
    ].each do |line, message|
      files, stderr = generate(world_source(line))

      expect(files).to be_nil
      expect(stderr).to match(message)
    end
  end
end
