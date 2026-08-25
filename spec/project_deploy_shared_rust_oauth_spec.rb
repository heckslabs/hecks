require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

# Regression coverage for the combination bin/project_deploy used to
# refuse outright: a Shared-mode domain (database "Shared") with real
# Google OAuth (web "Rust" + a .env.local carrying GOOGLE_CLIENT_ID).
# The refusal assumed OAuth needed its own NAT Gateway this domain has
# none of in Shared mode — but a Shared-mode rust_web domain's main
# dispatch function already runs inside the OWNER's borrowed private
# subnets/security group, which the owner's own template already
# routes through its NAT Gateway and already permits 443 egress on
# (added there for the owner's own real, live OAuth token-exchange
# bug). Nothing new to provision; this spec exists because the actual
# bug found while lifting the refusal was elsewhere — the Parameters
# section's own `if google_oauth_present ... elsif shared ...` treated
# the two as mutually exclusive, so the "both true" case silently
# dropped one entire set of Parameters even though Resources below
# already referenced them unconditionally. Mirrors
# spec/project_deploy_contract_spec.rb's own fixture-generation
# pattern.
RSpec.describe "bin/project_deploy — Shared mode + rust_web + real Google OAuth", io: true do
  SHARED_RUST_OAUTH_FIXTURE_BASENAME = "project_deploy_shared_rust_oauth_spec_fixture"

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

      _stdout, stderr, status = Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir)
      status.success? or raise "bin/project_deploy failed: #{stderr}"
    end

    @template = YAML.unsafe_load_file(File.join(@generated_dir, "template.yaml"))
    @raw = File.read(File.join(@generated_dir, "template.yaml"))
    @makefile = File.read(File.join(@generated_dir, "Makefile"))
  end

  # `deploy:`'s own recipe, lines only — line-based (not a single regex)
  # because the recipe has a genuine BLANK line inside it (between
  # `sam build` and `$(MAKE) sync-google-oauth`), which a naive
  # `(?:\t.*\n)+` line-of-recipe pattern stops matching at.
  def self.deploy_recipe_lines(makefile)
    lines = makefile.lines
    start = lines.index { |l| l == "deploy:\n" } or raise "no deploy: target found in the generated Makefile"
    lines[(start + 1)..].take_while { |l| l == "\n" || l.start_with?("\t") }
  end

  after(:context) { FileUtils.rm_rf(@generated_dir) }

  it "declares both the Owning* (Shared mode) and WebRedirectBaseUrl (OAuth) Parameters together, not as alternatives" do
    expect(@template["Parameters"]).to be_a(Hash)
    expect(@template["Parameters"].keys).to include(
      "OwningVpcId", "OwningSubnetAId", "OwningSubnetBId", "OwningSecurityGroupId",
      "OwningDatabaseEndpoint", "OwningDatabaseSecretArn", "WebRedirectBaseUrl"
    )
  end

  it "wires the main function's VpcConfig to the borrowed Owning* subnets/security group, not a locally-minted one" do
    expect(@raw).to include("SubnetIds: [!Ref OwningSubnetAId, !Ref OwningSubnetBId]")
    expect(@raw).to include("SecurityGroupIds: [!Ref OwningSecurityGroupId]")
  end

  it "mints no NAT Gateway or VPC of its own — Shared mode borrows the owner's, already NAT-routed" do
    expect(@template["Resources"].keys).not_to include(a_string_matching(/NatGateway\z/))
    expect(@template["Resources"].values).not_to include(satisfy { |r| r["Type"] == "AWS::EC2::VPC" })
  end

  it "wires the main function's own real Google OAuth Environment variables" do
    expect(@raw).to match(/GOOGLE_CLIENT_ID: !Sub "\{\{resolve:secretsmanager:hecks-#{SHARED_RUST_OAUTH_FIXTURE_BASENAME}-web-google-oauth:SecretString:client_id\}\}"/)
    expect(@raw).to include('GOOGLE_REDIRECT_URI: !Sub "${WebRedirectBaseUrl}/auth/google/callback"')
  end

  # The Parameters SECTION declaring both sets together (above) is
  # necessary but not sufficient — `deploy:`'s own `sam deploy` call is
  # a SEPARATE piece of generated code that has to actually PASS both
  # sets of values, or the stack it declared them for refuses at
  # deploy time with "Parameters: [...] must have values" no matter
  # how correct template.yaml itself is. The `if google_oauth_present
  # ... elsif shared ...` bug this file's own header describes was
  # fixed here first (Parameters section, #347) and left unfixed in
  # THIS sibling code for a full deploy cycle before being caught live
  # — this coverage is what should have caught it the first time.
  it "passes both the Owning* and WebRedirectBaseUrl overrides together in deploy:'s own sam deploy call" do
    recipe = self.class.deploy_recipe_lines(@makefile).join

    %w[OwningVpcId OwningSubnetAId OwningSubnetBId OwningSecurityGroupId
       OwningDatabaseEndpoint OwningDatabaseSecretArn].each do |param|
      expect(recipe).to include("#{param}=$$OWNER_"), "deploy: never passes #{param} to sam deploy"
    end
    expect(recipe.scan(/WebRedirectBaseUrl="\$\$WEB_URL"/).size).to eq(1),
                                                                     "deploy: should pass WebRedirectBaseUrl in its one real sam deploy call (the WEB_URL-present branch)"
  end

  it "deploy:'s own multi-line shell chain has exactly one Make '@' (echo-suppress) prefix, at its true first line" do
    lines = self.class.deploy_recipe_lines(@makefile)
    at_prefixed = lines.select { |l| l.lstrip.start_with?("@") }
    expect(at_prefixed.size).to eq(1),
                                 "expected exactly one '@'-prefixed recipe line (a SECOND one mid-chain stops being a Make " \
                                 "directive and becomes literal, invalid shell text once backslash-continuation joins " \
                                 "everything into one command) — got #{at_prefixed.size}: #{at_prefixed.inspect}"
  end

  it "deploy:'s own generated shell chain is syntactically valid shell" do
    lines = self.class.deploy_recipe_lines(@makefile)
    script = lines.map { |l| l.sub(/\A\t/, "") }.join.gsub("$$", "$")
    _stdout, stderr, status = Open3.capture3("bash", "-n", stdin_data: script)
    expect(status.success?).to be(true), "deploy:'s own recipe is not valid shell:\n#{stderr}\n---\n#{script}"
  end
end
