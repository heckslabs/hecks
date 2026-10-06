require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

# A Shared-mode domain with real Google OAuth must declare both Parameter sets: the
# google_oauth_present and shared branches must not be mutually exclusive.
RSpec.describe "hecks deploy project — Shared mode + rust_web + real Google OAuth", :io do
  SHARED_RUST_OAUTH_FIXTURE_BASENAME = "project_deploy_shared_rust_oauth_spec_fixture".freeze

  SHARED_OAUTH_OWNING_PARAMETERS = ["OwningVpcId", "OwningSubnetAId", "OwningSubnetBId", "OwningSecurityGroupId",
                                    "OwningDatabaseEndpoint", "OwningDatabaseSecretArn"].freeze

  SHARED_OAUTH_WEB_URL_MESSAGE = "deploy: should pass WebRedirectBaseUrl in its one " \
                                 "real sam deploy call (the WEB_URL-present branch)".freeze

  before(:context) do
    root = File.expand_path("..", __dir__)
    @generated_dir = File.join(root, "deploy", SHARED_RUST_OAUTH_FIXTURE_BASENAME)

    Dir.mktmpdir do |dir|
      domain_dir = File.join(dir, SHARED_RUST_OAUTH_FIXTURE_BASENAME)
      bluebook_dir = File.join(domain_dir, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)

      File.write(File.join(bluebook_dir, "#{SHARED_RUST_OAUTH_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
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

      File.write(File.join(bluebook_dir, "#{SHARED_RUST_OAUTH_FIXTURE_BASENAME}.world"), <<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsLambda") do
            region "us-east-1"
            database "Shared"
            owner "SomeOwner"
            web "Rust"
          end
        end
      WORLD

      File.write(File.join(domain_dir, ".env.local"), <<~ENV)
        GOOGLE_CLIENT_ID=test-client-id.apps.googleusercontent.com
        GOOGLE_CLIENT_SECRET=test-secret
      ENV

      _stdout, stderr, status = ProjectDeployRunner.run(domain_dir, root: root)
      status.success? or raise "hecks deploy project failed: #{stderr}"
    end

    @template = YAML.unsafe_load_file(File.join(@generated_dir, "template.yaml"))
    @raw = File.read(File.join(@generated_dir, "template.yaml"))
    @makefile = File.read(File.join(@generated_dir, "Makefile"))
  end

  # Line-based, not one regex: a blank line between `sam build` and `$(MAKE) sync-google-oauth`
  # stops a `(?:\t.*\n)+` pattern.
  def self.deploy_recipe_lines(makefile)
    lines = makefile.lines
    start = lines.index { |l| l == "deploy:\n" } or raise "no deploy: target found in the generated Makefile"
    lines[(start + 1)..].take_while { |l| l == "\n" || l.start_with?("\t") }
  end

  after(:context) { FileUtils.rm_rf(@generated_dir) }

  it "declares both the Owning* (Shared mode) and WebRedirectBaseUrl (OAuth) Parameters together, not as alternatives",
     :aggregate_failures do
    expect(@template["Parameters"]).to be_a(Hash)
    expect(@template["Parameters"].keys).to include(
      "OwningVpcId", "OwningSubnetAId", "OwningSubnetBId", "OwningSecurityGroupId",
      "OwningDatabaseEndpoint", "OwningDatabaseSecretArn", "WebRedirectBaseUrl"
    )
  end

  it "wires the main function's VpcConfig to the borrowed Owning* subnets/security group, not a locally-minted one",
     :aggregate_failures do
    expect(@raw).to include("SubnetIds: [!Ref OwningSubnetAId, !Ref OwningSubnetBId]")
    expect(@raw).to include("SecurityGroupIds: [!Ref OwningSecurityGroupId]")
  end

  it "mints no NAT Gateway or VPC of its own — Shared mode borrows the owner's, already NAT-routed", :aggregate_failures do
    expect(@template["Resources"].keys).not_to include(a_string_matching(/NatGateway\z/))
    expect(@template["Resources"].values).not_to include(satisfy { |r| r["Type"] == "AWS::EC2::VPC" })
  end

  it "wires the main function's own real Google OAuth Environment variables", :aggregate_failures do
    expect(@raw).to include("GOOGLE_OAUTH_SECRET_ID: hecks-#{SHARED_RUST_OAUTH_FIXTURE_BASENAME}-web-google-oauth")
    expect(@raw).to include('GOOGLE_REDIRECT_URI: !Sub "${WebRedirectBaseUrl}/auth/google/callback"')
    expect(@raw).to match(/SESSION_SECRET_ARN: !Sub "\$\{\w+SessionSecret\}"/)
  end

  # The execution role must fetch both secrets named by GOOGLE_OAUTH_SECRET_ID/SESSION_SECRET_ARN,
  # extending the DB secret's grant rather than adding a second Policies key.
  it "grants the main function's role secretsmanager:GetSecretValue on both the Google OAuth secret and the session secret",
     :aggregate_failures do
    function = @template["Resources"].values.find { |r| r["Type"] == "AWS::Serverless::Function" && r.dig("Properties", "Environment", "Variables", "GOOGLE_OAUTH_SECRET_ID") }
    statements = function.dig("Properties", "Policies").flat_map { |p| p["Statement"] || [] }
    resources = statements.select { |s| s["Action"] == "secretsmanager:GetSecretValue" }.map { |s| s["Resource"] }

    expect(resources).to include(a_string_matching(/-web-google-oauth-\*\z/))
    expect(resources).to include(a_string_matching(/SessionSecret\}\z/))
  end

  # Declaring both Parameter sets is not enough: `sam deploy` must pass values for both, or the
  # stack refuses at deploy time with "Parameters: [...] must have values".
  it "passes both the Owning* and WebRedirectBaseUrl overrides together in deploy:'s own sam deploy call", :aggregate_failures do
    recipe = self.class.deploy_recipe_lines(@makefile).join
    unpassed = SHARED_OAUTH_OWNING_PARAMETERS.reject { |param| recipe.include?("#{param}=$$OWNER_") }

    expect(unpassed).to be_empty, "deploy: never passes #{unpassed.join(", ")} to sam deploy"
    expect(recipe.scan('WebRedirectBaseUrl="$$WEB_URL"').size).to eq(1), SHARED_OAUTH_WEB_URL_MESSAGE
  end

  # `deploy:` is several independent shell invocations, not one chain. A second '@' inside one
  # backslash-joined chain becomes literal invalid shell, so check per chain, not per recipe: a
  # target may carry several independent '@' lines (see mint_era_recipe's `OWNMINT` branch).
  def self.shell_chains(lines)
    lines.reject { |l| l == "\n" }.slice_after { |l| !l.rstrip.end_with?("\\") }.to_a
  end

  SHARED_OAUTH_AT_MESSAGE = "expected at most one '@'-prefixed line in this shell chain (a SECOND one " \
                            "mid-chain stops being a Make directive and becomes literal, invalid shell " \
                            "text once backslash-continuation joins everything into one command) — " \
                            "got %<count>d in chain: %<chain>s".freeze

  def expect_at_prefixed_once(chain)
    indices = chain.each_index.select { |i| chain[i].lstrip.start_with?("@") }

    expect(indices.size).to be <= 1, format(SHARED_OAUTH_AT_MESSAGE, count: indices.size, chain: chain.inspect)
    expect(indices).to eq([0]) if indices.any?
  end

  it "never has a second Make '@' (echo-suppress) prefix mid-chain — only ever at a chain's true first line",
     :aggregate_failures do
    chains = self.class.shell_chains(self.class.deploy_recipe_lines(@makefile))

    chains.each { |chain| expect_at_prefixed_once(chain) }
  end

  it "deploy:'s own generated shell chain is syntactically valid shell" do
    lines = self.class.deploy_recipe_lines(@makefile)
    script = lines.map { |l| l.delete_prefix("\t") }.join.gsub("$$", "$")
    _stdout, stderr, status = Open3.capture3("bash", "-n", stdin_data: script)
    expect(status.success?).to be(true), "deploy:'s own recipe is not valid shell:\n#{stderr}\n---\n#{script}"
  end
end
