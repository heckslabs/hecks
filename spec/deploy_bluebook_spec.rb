require_relative "support/project_deploy_runner"
require "hecks"
require "tmpdir"
require "fileutils"
require "open3"

# Deploy settings for deployed_to("AwsLambda") are validated by the Deploy domain itself.
# Also pins that hecks deploy project dispatches into it rather than hand-rolled checks.
RSpec.describe "the self-hosted Deploy bluebook" do
  DEPLOY_DOMAIN = File.expand_path("../lib/hecks/deploy", __dir__)

  def dispatcher
    @dispatcher ||= Hecks.boot(DEPLOY_DOMAIN)
  end

  def declare(overrides = {})
    args = {
      domain:   { value: "Banking" },
      region:   { value: "us-east-1" },
      memory:   { value: 512 },
      timeout:  { value: 10 },
      # Same defaults hecks deploy project applies when a domain names neither.
      database: { value: "Postgres" },
      web:      { value: "None" }
    }.merge(overrides)
    dispatcher.dispatch_flat("Deploy::LambdaTarget.Declare", **args)
  end

  # The values of the named attributes of the instance a Declare produced.
  def values_of(result, *names)
    state = result.instance.state
    names.to_h { |name| [name, state[name].value] }
  end

  it "accepts a fully-specified, in-range target" do
    values = values_of(declare, :domain, :region, :memory, :timeout)

    expect(values).to eq(domain: "Banking", region: "us-east-1", memory: 512, timeout: 10)
  end

  it "accepts a webhook target that skips the dispatch Lambda and names its handler module", :aggregate_failures do
    state = declare(dispatch: { value: "None" }, handler_module: { value: "QaWebhookLambdaHandler" },
                    secret_env: { value: "GITHUB_WEBHOOK_SECRET" }).instance.state

    expect(state[:dispatch].value).to eq("None")
    expect(state[:handler_module].value).to eq("QaWebhookLambdaHandler")
    expect(state[:secret_env].value).to eq("GITHUB_WEBHOOK_SECRET")
  end

  it "accepts dispatch \"Rust\" with no handler module" do
    expect(declare(dispatch: { value: "Rust" }).instance.state[:dispatch].value).to eq("Rust")
  end

  it "refuses dispatch \"None\" with no handler module" do
    expect { declare(dispatch: { value: "None" }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /dispatch "None" names its handler_module/)
  end

  it "refuses a dispatch other than Rust or None" do
    expect { declare(dispatch: { value: "Ruby" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /Ruby|one of/i)
  end

  it "refuses an empty handler module" do
    expect { declare(handler_module: { value: "" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a handler module is named/)
  end

  # C3.7 (docs/semantics/bluebook-semantics.md): required fields are checked before invariants,
  # so an explicit nil is TypeMismatch while an empty string reaches the invariant.
  it "refuses an absent region" do
    expect { declare(region: { value: nil }) }
      .to raise_error(Hecks::Runtime::TypeMismatch, /Region\.value expects String, got nil/)
  end

  it "refuses an empty region" do
    expect { declare(region: { value: "" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /Region invariant violated — a region is named/)
  end

  it "refuses memory below Lambda's own 128 MB floor" do
    expect { declare(memory: { value: 64 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /memory is at least 128 MB/)
  end

  it "refuses memory above Lambda's own 10240 MB ceiling" do
    expect { declare(memory: { value: 20_000 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /memory is at most 10240 MB/)
  end

  it "refuses a non-positive timeout" do
    expect { declare(timeout: { value: 0 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a timeout is positive/)
  end

  it "refuses a timeout above Lambda's own 900s ceiling" do
    expect { declare(timeout: { value: 1000 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /fits Lambda's own 900s ceiling/)
  end

  it "accepts \"Aurora\" for database" do
    result = declare(database: { value: "Aurora" })
    expect(result.instance.state[:database].value).to eq("Aurora")
  end

  it "accepts \"Shared\" for database" do
    result = declare(database: { value: "Shared" })
    expect(result.instance.state[:database].value).to eq("Shared")
  end

  it "refuses a database outside {Postgres, Aurora, Shared}" do
    expect { declare(database: { value: "MySQL" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation)
  end

  it "accepts \"Rust\" for web" do
    result = declare(web: { value: "Rust" })
    expect(result.instance.state[:web].value).to eq("Rust")
  end

  it "refuses a web value outside {None, Rust}" do
    expect { declare(web: { value: "Ruby" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation)
  end

  def declare_fargate(overrides = {})
    args = {
      domain:   { value: "Banking" },
      region:   { value: "us-east-1" },
      cpu:      { value: 256 },
      memory:   { value: 512 },
      database: { value: "Postgres" },
      web:      { value: "None" },
      port:     { value: 8080 }
    }.merge(overrides)
    dispatcher.dispatch_flat("Deploy::FargateTarget.Declare", **args)
  end

  it "accepts a fully-specified AwsFargate target" do
    values = values_of(declare_fargate, :domain, :region, :cpu, :memory, :port)

    expect(values).to eq(domain: "Banking", region: "us-east-1", cpu: 256, memory: 512, port: 8080)
  end

  it "refuses an empty region for AwsFargate" do
    expect { declare_fargate(region: { value: "" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /Region invariant violated — a region is named/)
  end

  it "refuses a non-positive cpu" do
    expect { declare_fargate(cpu: { value: 0 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /cpu is positive/)
  end

  it "refuses a non-positive memory" do
    expect { declare_fargate(memory: { value: 0 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /memory is positive/)
  end

  it "refuses memory above Fargate's own ceiling" do
    expect { declare_fargate(memory: { value: 999_999 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /memory is at most 122880 MB/)
  end

  it "refuses a database outside {Postgres, Aurora, Shared} for AwsFargate" do
    expect { declare_fargate(database: { value: "MySQL" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation)
  end

  it "accepts \"Shared\" for database on AwsFargate" do
    result = declare_fargate(database: { value: "Shared" })
    expect(result.instance.state[:database].value).to eq("Shared")
  end

  it "refuses a web value outside {None, Rust} for AwsFargate" do
    expect { declare_fargate(web: { value: "Ruby" }) }
      .to raise_error(Hecks::Runtime::InvariantViolation)
  end

  it "refuses a port below 1" do
    expect { declare_fargate(port: { value: 0 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a port is at least 1/)
  end

  it "refuses a port above 65535" do
    expect { declare_fargate(port: { value: 70_000 }) }
      .to raise_error(Hecks::Runtime::InvariantViolation, /a port is at most 65535/)
  end

  def declare_box(**overrides)
    args = {
      domain:         { value: "Storefront" },
      region:         { value: "us-east-1" },
      instance_type:  { value: "t4g.medium" },
      volume_gb:      { value: 30 },
      database_class: { value: "db.t4g.small" },
      storage_gb:     { value: 20 }
    }.merge(overrides)
    dispatcher.dispatch_flat("Deploy::BoxTarget.Declare", **args)
  end

  def declare_shared_database(**overrides)
    args = { domain: { value: "Platform" }, region: { value: "us-east-1" }, database_class: { value: "db.t4g.small" },
             storage_gb: { value: 30 } }.merge(overrides)
    dispatcher.dispatch_flat("Deploy::SharedDatabaseTarget.Declare", **args)
  end

  describe "SharedDatabaseTarget.Declare" do
    it "accepts a fully-specified AwsSharedDatabase target" do
      values = values_of(declare_shared_database, :domain, :database_class, :storage_gb)

      expect(values).to eq(domain: "Platform", database_class: "db.t4g.small", storage_gb: 30)
    end

    it "refuses an empty region" do
      expect { declare_shared_database(region: { value: "" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /a region is named/)
    end

    it "refuses a database class that is not db.family.size" do
      expect { declare_shared_database(database_class: { value: "t4g.small" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /a database class is db.family.size/)
    end

    it "refuses storage below 20 GB and above 65536 GB", :aggregate_failures do
      expect { declare_shared_database(storage_gb: { value: 10 }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /storage is at least 20 GB/)
      expect { declare_shared_database(storage_gb: { value: 70_000 }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /storage is at most 65536 GB/)
    end
  end

  describe "BoxTarget.Declare" do
    it "accepts a fully-specified AwsBox target" do
      values = values_of(declare_box, :domain, :instance_type, :volume_gb, :database_class, :storage_gb)

      expect(values).to eq(domain: "Storefront", instance_type: "t4g.medium", volume_gb: 30,
                           database_class: "db.t4g.small", storage_gb: 20)
    end

    it "refuses an empty region" do
      expect { declare_box(region: { value: "" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /a region is named/)
    end

    it "refuses an instance type that is not family.size" do
      expect { declare_box(instance_type: { value: "medium" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /an instance type is family.size/)
    end

    it "refuses a database class that is not db.family.size" do
      expect { declare_box(database_class: { value: "t4g.small" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /a database class is db.family.size/)
    end

    it "refuses a volume below 8 GB and one above 16384 GB", :aggregate_failures do
      expect { declare_box(volume_gb: { value: 4 }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /a volume is at least 8 GB/)
      expect { declare_box(volume_gb: { value: 20_000 }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /a volume is at most 16384 GB/)
    end

    it "refuses storage below RDS's 20 GB floor" do
      expect { declare_box(storage_gb: { value: 10 }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /storage is at least 20 GB/)
    end
  end

  # End-to-end: hecks deploy project must dispatch into this domain, not a parallel check.
  describe "hecks deploy project, driven through a scratch fixture domain", :io do
    # hecks deploy project always writes to <repo_root>/deploy/<basename>, wherever the source
    # lives, so the basename is unique and the generated directory is removed after every run.
    FIXTURE_BASENAME = "deploy_bluebook_spec_fixture".freeze

    SCRATCH_FIXTURE_BLUEBOOK = <<~BLUEBOOK.freeze
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

    # The extra files that enable WebFunction and its secret, so a prefix is checked on them too.
    WEB_OAUTH_FILES = { "lambda_handler.rb" => "# scratch\n",
                        "Gemfile.lock"      => "GEM\n  specs:\n    pg (1.5.9)\n",
                        ".env.local"        => "GOOGLE_CLIENT_ID=placeholder\n" }.freeze

    def repo_root = File.expand_path("..", __dir__)

    # A world that deploys the scratch domain to AwsLambda with the given settings.
    def lambda_world(*settings)
      body = settings.map { |setting| "    #{setting}\n" }.join
      "Hecks.world \"Scratch\" do\n  deployed_to(\"AwsLambda\") do\n#{body}  end\nend\n"
    end

    # Shared with the owner_stack test, which must read the Makefile before cleanup removes it.
    def write_scratch_fixture_bluebook(domain_dir)
      bluebook_dir = File.join(domain_dir, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)
      File.write(File.join(bluebook_dir, "#{FIXTURE_BASENAME}.bluebook"), SCRATCH_FIXTURE_BLUEBOOK)
      bluebook_dir
    end

    # Writes the scratch domain with `world_body` and the `extra_files`, runs hecks deploy project on
    # it and yields the runner's answer with the generated directory, which is removed afterwards.
    def deploy_scratch(world_body, extra_files = {})
      generated_dir = File.join(repo_root, "deploy", FIXTURE_BASENAME)
      Dir.mktmpdir do |dir|
        domain_dir = File.join(dir, FIXTURE_BASENAME)
        bluebook_dir = write_scratch_fixture_bluebook(domain_dir)
        File.write(File.join(bluebook_dir, "#{FIXTURE_BASENAME}.world"), world_body)
        extra_files.each { |name, text| File.write(File.join(domain_dir, name), text) }
        yield ProjectDeployRunner.run(domain_dir, root: repo_root), generated_dir
      end
    ensure
      FileUtils.rm_rf(generated_dir)
    end

    def run_project_deploy(world_body) = deploy_scratch(world_body) { |result, _generated_dir| result }

    # stack_prefix renames this domain's stack, functions and OAuth secret.
    # `web_oauth: true` adds the files that enable WebFunction and its secret, so the prefix
    # is checked on the second function and the secret too.
    def generate_with_world(world_body, web_oauth: false)
      deploy_scratch(world_body, web_oauth ? WEB_OAUTH_FILES : {}) do |(_stdout, stderr, status), generated_dir|
        status.success? or raise "hecks deploy project failed: #{stderr}"

        %w[template.yaml Makefile samconfig.toml].to_h { |f| [f, File.read(File.join(generated_dir, f))] }
      end
    end

    it "generates cleanly for a valid deployed_to(\"AwsLambda\") block" do
      _stdout, stderr, status = run_project_deploy(lambda_world('region "us-east-1"'))

      expect(status).to be_success, stderr
    end

    it "refuses with the new domain-refusal wording, not the old hand-written abort string", :aggregate_failures do
      _stdout, stderr, status = run_project_deploy(lambda_world('region "us-east-1"', "memory 64"))

      expect(status).not_to be_success
      expect(stderr).to include("is invalid:")
      expect(stderr).to include("memory is at least 128 MB")
    end

    it 'generates cleanly for database "Shared" with an owner declared' do
      _stdout, stderr, status = run_project_deploy(lambda_world('region "us-east-1"', 'database "Shared"', 'owner "Core"'))

      expect(status).to be_success, stderr
    end

    # owner_stack overrides the hecks-<owner> stack-name convention for an owner whose live stack
    # is named differently. Reads the generated Makefile directly because run_project_deploy
    # removes it before returning.
    it "uses a declared owner_stack override instead of the ordinary hecks-<owner> convention", :aggregate_failures do
      world = lambda_world('region "us-east-1"', 'database "Shared"', 'owner "Core"', 'owner_stack "custom-core-stack"')
      makefile = generate_with_world(world)["Makefile"]

      expect(makefile).to include("--stack-name custom-core-stack")
      expect(makefile).not_to include("--stack-name hecks-core")
    end

    it "names the stack hecks-<name> when no stack_prefix is declared", :aggregate_failures do
      files = generate_with_world(lambda_world('region "us-east-1"'))

      expect(files["samconfig.toml"]).to include(%(stack_name = "hecks-#{FIXTURE_BASENAME}"))
      expect(files["template.yaml"]).to include("FunctionName: hecks-#{FIXTURE_BASENAME}")
    end

    context "with a declared stack_prefix" do
      let(:expected) { "acme-#{FIXTURE_BASENAME}" }
      let(:files) { generate_with_world(lambda_world('region "us-east-1"', 'stack_prefix "acme"'), web_oauth: true) }
      let(:prefixed) do
        ["FunctionName: #{expected}\n", "FunctionName: #{expected}-web\n", "GOOGLE_OAUTH_SECRET_ID: #{expected}-web-google-oauth"]
      end

      it "uses it for the stack, function, and secret names", :aggregate_failures do
        expect(files["samconfig.toml"]).to include(%(stack_name = "#{expected}"))
        expect(files["template.yaml"]).to include(*prefixed)
        expect(files["Makefile"]).to include(expected)
        expect(files.values.join).not_to include("hecks-#{FIXTURE_BASENAME}")
      end
    end

    it 'refuses database "Shared" with no owner declared', :aggregate_failures do
      _stdout, stderr, status = run_project_deploy(lambda_world('region "us-east-1"', 'database "Shared"'))

      expect(status).not_to be_success
      expect(stderr).to include("declares database \"Shared\" but no owner")
    end

    it "never claims to have written bastion.yaml for a Shared-mode domain", :aggregate_failures do
      stdout, stderr, status = run_project_deploy(lambda_world('region "us-east-1"', 'database "Shared"', 'owner "Core"'))

      expect(status).to be_success, stderr
      expect(stdout).not_to include("bastion.yaml")
    end
  end
end
