require "hecksagain"
require "tmpdir"
require "fileutils"
require "open3"

# `lib/hecksagain/deploy/bluebook/deploy.bluebook`'s own header explains
# WHY this domain exists: `deployed_to("AwsLambda")`'s settings used to
# be validated nowhere in the language — a bare `fetch(:region) { abort
# ... }` chain in bin/project_deploy, the exact raw-Ruby-refusal pattern
# every OTHER kind of bluebook mistake in this codebase does NOT use.
# This asserts the domain itself validates correctly, and that
# bin/project_deploy genuinely dispatches into it rather than falling
# back to hand-rolled checks.
RSpec.describe "the self-hosted Deploy bluebook" do
  DEPLOY_DOMAIN = File.expand_path("../lib/hecksagain/deploy", __dir__)

  def dispatcher
    @dispatcher ||= Hecks.boot(DEPLOY_DOMAIN)
  end

  def declare(overrides = {})
    args = {
      domain:   { value: "Banking" },
      region:   { value: "us-east-1" },
      memory:   { value: 512 },
      timeout:  { value: 10 },
      # "Postgres"/"None" — bin/project_deploy's own Ruby-side
      # defaults (deploy_settings.fetch(:database, "Postgres") /
      # .fetch(:web, "None")) when a domain's own deployed_to("AwsLambda")
      # names neither — Embryonaut's own live choice either way.
      database: { value: "Postgres" },
      web:      { value: "None" }
    }.merge(overrides)
    dispatcher.dispatch("Deploy::LambdaTarget.Declare", **args)
  end

  it "accepts a fully-specified, in-range target" do
    result = declare
    state = result.instance.state
    expect(state[:domain].value).to eq("Banking")
    expect(state[:region].value).to eq("us-east-1")
    expect(state[:memory].value).to eq(512)
    expect(state[:timeout].value).to eq(10)
  end

  it "refuses an absent region" do
    expect { declare(region: { value: nil }) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /Region invariant violated — a region is named/)
  end

  it "refuses memory below Lambda's own 128 MB floor" do
    expect { declare(memory: { value: 64 }) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /memory is at least 128 MB/)
  end

  it "refuses memory above Lambda's own 10240 MB ceiling" do
    expect { declare(memory: { value: 20_000 }) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /memory is at most 10240 MB/)
  end

  it "refuses a non-positive timeout" do
    expect { declare(timeout: { value: 0 }) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /a timeout is positive/)
  end

  it "refuses a timeout above Lambda's own 900s ceiling" do
    expect { declare(timeout: { value: 1000 }) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation, /fits Lambda's own 900s ceiling/)
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
      .to raise_error(Hecksagain::Runtime::InvariantViolation)
  end

  it "accepts \"Rust\" for web" do
    result = declare(web: { value: "Rust" })
    expect(result.instance.state[:web].value).to eq("Rust")
  end

  it "refuses a web value outside {None, Rust}" do
    expect { declare(web: { value: "Ruby" }) }
      .to raise_error(Hecksagain::Runtime::InvariantViolation)
  end

  # THE END-TO-END PROOF — bin/project_deploy itself dispatches into
  # this domain, not a parallel hand-rolled check that happens to agree
  # with it today and silently drifts tomorrow.
  describe "bin/project_deploy, driven through a scratch fixture domain", io: true do
    # `bin/project_deploy` always writes to `<repo_root>/deploy/
    # <domain_basename>` regardless of where the SOURCE domain lives
    # (`root`/`out_dir` in bin/project_deploy are computed from the
    # SCRIPT's own location, not the input path) — so the domain
    # basename here is deliberately unique and the generated directory
    # is removed after every run, or each example would leave a real,
    # permanent `deploy/scratch/` behind in the actual repo.
    FIXTURE_BASENAME = "deploy_bluebook_spec_fixture"

    def run_project_deploy(world_body)
      root = File.expand_path("..", __dir__)
      generated_dir = File.join(root, "deploy", FIXTURE_BASENAME)

      Dir.mktmpdir do |dir|
        domain_dir = File.join(dir, FIXTURE_BASENAME)
        bluebook_dir = File.join(domain_dir, "bluebook")
        FileUtils.mkdir_p(bluebook_dir)

        File.write(File.join(bluebook_dir, "#{FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
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

        File.write(File.join(bluebook_dir, "#{FIXTURE_BASENAME}.world"), world_body)

        Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir)
      end
    ensure
      FileUtils.rm_rf(generated_dir)
    end

    it "generates cleanly for a valid deployed_to(\"AwsLambda\") block" do
      _stdout, stderr, status = run_project_deploy(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsLambda") do
            region "us-east-1"
          end
        end
      WORLD

      expect(status).to be_success, stderr
    end

    it "refuses with the new domain-refusal wording, not the old hand-written abort string" do
      _stdout, stderr, status = run_project_deploy(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsLambda") do
            region "us-east-1"
            memory 64
          end
        end
      WORLD

      expect(status).not_to be_success
      expect(stderr).to include("is invalid:")
      expect(stderr).to include("memory is at least 128 MB")
    end

    it 'generates cleanly for database "Shared" with an owner declared' do
      _stdout, stderr, status = run_project_deploy(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsLambda") do
            region "us-east-1"
            database "Shared"
            owner "Embryonaut"
          end
        end
      WORLD

      expect(status).to be_success, stderr
    end

    it 'refuses database "Shared" with no owner declared' do
      _stdout, stderr, status = run_project_deploy(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsLambda") do
            region "us-east-1"
            database "Shared"
          end
        end
      WORLD

      expect(status).not_to be_success
      expect(stderr).to include("declares database \"Shared\" but no owner")
    end

    it "never claims to have written bastion.yaml for a Shared-mode domain" do
      stdout, stderr, status = run_project_deploy(<<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsLambda") do
            region "us-east-1"
            database "Shared"
            owner "Embryonaut"
          end
        end
      WORLD

      expect(status).to be_success, stderr
      expect(stdout).not_to include("bastion.yaml")
    end
  end
end
