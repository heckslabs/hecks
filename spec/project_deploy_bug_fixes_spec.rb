require_relative "support/project_deploy_runner"
require "tmpdir"
require "fileutils"
require "open3"

# Regression coverage for four bugs in hecks deploy project's generated Makefile
# (H13, H14, M28, M29). Each context shells out once and asserts on the real output.
RSpec.describe "hecks deploy project — H13/H14/M28/M29 regressions", :io do
  def self.root = File.expand_path("..", __dir__)

  def self.write_fixture(dir, basename, world_body, env_local: nil)
    domain_dir = File.join(dir, basename)
    bluebook_dir = File.join(domain_dir, "bluebook")
    FileUtils.mkdir_p(bluebook_dir)
    bluebook_name = basename.split("_").map(&:capitalize).join

    File.write(File.join(bluebook_dir, "#{basename}.bluebook"), <<~BLUEBOOK)
      Hecks.bluebook "#{bluebook_name}" do
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

    File.write(File.join(bluebook_dir, "#{basename}.world"), <<~WORLD)
      Hecks.world "#{bluebook_name}" do
        deployed_to("AwsLambda") do
          #{world_body}
        end
      end
    WORLD

    File.write(File.join(domain_dir, ".env.local"), env_local) if env_local

    domain_dir
  end

  # Generates the fixture and returns <repo_root>/deploy/<basename>, where
  # hecks deploy project always writes.
  def self.generate!(basename, world_body, env_local: nil)
    Dir.mktmpdir do |dir|
      domain_dir = write_fixture(dir, basename, world_body, env_local: env_local)
      _stdout, stderr, status = ProjectDeployRunner.run(domain_dir, root: root)
      status.success? or raise "hecks deploy project failed: #{stderr}"
    end
    File.join(root, "deploy", basename)
  end

  # Extracts a Make target's recipe lines: those following "target:\n".
  def self.recipe_lines(makefile, target)
    lines = makefile.lines
    start = lines.index { |l| l == "#{target}:\n" } or raise "no #{target}: target found in the generated Makefile"
    # Column-0 comments between "target:" and the tab-prefixed lines belong to the target.
    lines[(start + 1)..].take_while { |l| l == "\n" || l.start_with?("\t") || l.start_with?("#") }
  end

  # Splits a recipe into shell chains: Make runs each run of backslash-continued
  # lines as one shell invocation. Comment lines are dropped.
  def self.shell_chains(lines)
    body = lines.reject { |l| l.sub(/\A\t/, "").start_with?("#") || l == "\n" }
    chains = []
    current = []
    body.each do |line|
      stripped = line.sub(/\A\t/, "").chomp
      current << stripped
      unless stripped.end_with?("\\")
        chains << current
        current = []
      end
    end
    chains << current unless current.empty?
    chains
  end

  # One own-RDS fixture shared by H14 and M29.
  before(:context) { @own_dir = self.class.generate!("h14_m29_own_fixture", <<~WORLD) }
    region "us-east-1"
  WORLD

  after(:context) { FileUtils.rm_rf(@own_dir) }

  describe "H13 — Shared-mode mint-era no longer poisons a successful deploy's exit code" do
    before(:context) { @generated_dir = self.class.generate!("h13_shared_fixture", <<~WORLD) }
      region "us-east-1"
      database "Shared"
      owner "SomeOwner"
    WORLD

    after(:context) { FileUtils.rm_rf(@generated_dir) }

    it "exits 0 (not 1) from the Shared-mode mint-era stub, in the generated recipe text" do
      makefile = File.read(File.join(@generated_dir, "Makefile"))
      recipe = self.class.recipe_lines(makefile, "mint-era").join

      expect(recipe).to include("isn't automated yet for a Shared-mode domain")
      expect(recipe).to match(/\bexit 0\b/)
      expect(recipe).not_to match(/\bexit 1\b/),
                            "Shared-mode mint-era should never exit 1 after reporting its manual-step message " \
                            "(deploy:'s own trailing `$(MAKE) mint-era` is unconditional, so a nonzero exit here " \
                            "makes a fully successful `make deploy` look failed)"
    end

    it "make mint-era actually exits 0 when run for real against a Shared-mode fixture" do
      _stdout, _stderr, status = Open3.capture3("make", "mint-era", chdir: @generated_dir)
      expect(status.success?).to be(true), "make mint-era should exit 0 for a Shared-mode domain, not fail a successful deploy"
    end
  end

  describe "H14 — scaffold-translation/translation-audit refuse instead of silently running against the local DB" do
    %w[scaffold-translation translation-audit].each do |target|
      it "#{target} refuses up front unless ALLOW_LOCAL_DB is set, before doing anything with AWS" do
        makefile = File.read(File.join(@own_dir, "Makefile"))
        recipe = self.class.recipe_lines(makefile, target).join
        chains = self.class.shell_chains(self.class.recipe_lines(makefile, target))

        expect(recipe).to include("ALLOW_LOCAL_DB")
        expect(recipe).to include("REFUSING")
        expect(recipe).to match(/resolves its OWN database connection from .* \.world file, NOT from DATABASE_URL/)

        # The guard must be the first chain, before any lookup, bastion or tunnel.
        expect(chains.first.join).to include("ALLOW_LOCAL_DB"),
                                     "the ALLOW_LOCAL_DB guard must be the FIRST thing #{target} does, not spliced in " \
                                     "after bastion/tunnel setup has already started"
      end

      it "#{target} really does refuse when actually run, and stops before touching the tunnel" do
        stdout, stderr, status = Open3.capture3("make", target, chdir: @own_dir)
        expect(status.success?).to be(false), "#{target} should refuse (nonzero exit) without ALLOW_LOCAL_DB set"
        expect(stderr + stdout).to include("REFUSING")
      end
    end

    it "does not add the ALLOW_LOCAL_DB guard to migrate-console-settings (an app-owned script, not asserted env-blind)" do
      makefile = File.read(File.join(@own_dir, "Makefile"))
      recipe = self.class.recipe_lines(makefile, "migrate-console-settings").join
      expect(recipe).not_to include("ALLOW_LOCAL_DB")
    end
  end

  describe "M28 — adding Google OAuth to an existing stack no longer deadlocks the pre-deploy mint-era bridge" do
    before(:context) do
      # A single-line string, not a heredoc: load_hygiene_spec.rb scans for
      # column-0 GOOGLE_CLIENT_ID= lines and would flag a false collision.
      env_local = %(GOOGLE_CLIENT_ID=test-client-id.apps.googleusercontent.com\nGOOGLE_CLIENT_SECRET=test-secret\n)
      @oauth_dir = self.class.generate!("m28_oauth_fixture", <<~WORLD, env_local: env_local)
        region "us-east-1"
        web "Rust"
      WORLD
      @plain_dir = self.class.generate!("m28_plain_fixture", <<~WORLD)
        region "us-east-1"
      WORLD
    end

    after(:context) do
      FileUtils.rm_rf(@oauth_dir)
      FileUtils.rm_rf(@plain_dir)
    end

    it "skips the pre-deploy bridge when PublicSubnetId isn't live yet, for an OAuth-present domain" do
      makefile = File.read(File.join(@oauth_dir, "Makefile"))
      recipe = self.class.recipe_lines(makefile, "deploy").join

      expect(recipe).to include("OutputKey=='PublicSubnetId'")
      expect(recipe).to include("skipping the pre-deploy bridge")
      # Not a blanket skip: the mint-era call stays reachable once the output is live.
      expect(recipe).to include("$(MAKE) mint-era || exit 1")
    end

    it "leaves the plain (no OAuth) pre-deploy bridge unconditional, as before" do
      makefile = File.read(File.join(@plain_dir, "Makefile"))
      recipe = self.class.recipe_lines(makefile, "deploy").join

      expect(recipe).not_to include("PublicSubnetId")
      expect(recipe).to include("bridging era history before this deploy flips $(STACK) over, not after")
    end

    it "generates syntactically valid shell for both the OAuth and plain deploy: pre-deploy bridges" do
      [@oauth_dir, @plain_dir].each do |generated_dir|
        makefile = File.read(File.join(generated_dir, "Makefile"))
        chains = self.class.shell_chains(self.class.recipe_lines(makefile, "deploy"))

        chains.each do |chain|
          # Make strips a leading "@" before handing the chain to the shell.
          script = chain.join("\n").sub(/\A@/, "").gsub("$$", "$")
          _stdout, stderr, status = Open3.capture3("bash", "-n", stdin_data: script)
          expect(status.success?).to be(true),
                                     "invalid shell chain in #{generated_dir}'s deploy: recipe:\n#{stderr}\n---\n#{script}"
        end
      end
    end
  end

  describe "M29 — the RDS master password is percent-encoded before it reaches a postgres:// URI" do
    it "derives DB_PASS_URLENC via ERB::Util.url_encode and uses it (not raw DB_PASS) in every DATABASE_URL" do
      makefile = File.read(File.join(@own_dir, "Makefile"))

      expect(makefile).to include("DB_PASS_URLENC=$$(ruby -rerb -e 'print ERB::Util.url_encode(ARGV[0])' \"$$DB_PASS\")")

      database_url_lines = makefile.lines.grep(%r{DATABASE_URL="postgres://})
      expect(database_url_lines).not_to be_empty
      expect(database_url_lines).to all(include('DATABASE_URL="postgres://postgres:$$DB_PASS_URLENC@')),
                                    "every DATABASE_URL built from DB_PASS should use the percent-encoded " \
                                    "DB_PASS_URLENC, not the raw password (libpq's URI parser rejects a bare `%`)"
      expect(database_url_lines).not_to include(a_string_matching(/\$\$DB_PASS@/)),
                                        "found a DATABASE_URL still built from the raw (un-encoded) DB_PASS"
    end

    it "leaves the rename-schema recipe's PGPASSWORD usage as the raw password (psql, not a URI, needs it unencoded)" do
      makefile = File.read(File.join(@own_dir, "Makefile"))
      recipe = self.class.recipe_lines(makefile, "rename-schema").join

      expect(recipe).to include("PGPASSWORD=$$DB_PASS psql")
      expect(recipe).not_to include("PGPASSWORD=$$DB_PASS_URLENC")
    end
  end
end
