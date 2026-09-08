require "tmpdir"
require "fileutils"
require "open3"

# Regression coverage for four bugs found in the 2026-08-10 audit
# (docs/audits/2026-08-10-main-bug-audit.md, triaged in
# docs/audits/2026-08-11-bug-triage.md) against bin/project_deploy's
# GENERATED Makefile output. Structural/text-based, mirroring the
# existing convention in this directory (project_deploy_contract_spec.rb,
# project_deploy_shared_rust_oauth_spec.rb): bin/project_deploy is a
# script with nothing to require, so each context here shells out to it
# once (in a before(:context)) and asserts on the real generated
# Makefile text.
#
#   H13 — a Shared-mode domain's `mint-era` stub used to `exit 1` after
#         reporting a manual step remains, so `deploy:`'s own
#         unconditional trailing `$(MAKE) mint-era` made a fully
#         successful `make deploy` always exit nonzero.
#   H14 — `scaffold-translation`/`translation-audit` open a real SSM
#         tunnel to production, then run scripts that resolve their DB
#         connection from the domain's `.world` file, not from the
#         DATABASE_URL/HECKS_SCHEMA this recipe exports — silently
#         scaffolding/auditing the LOCAL dev database while reporting
#         success. Fixed here by refusing (loudly) unless
#         ALLOW_LOCAL_DB=1 is set, rather than silently doing the wrong
#         thing — see translation_recipe's own `db_env_blind` comment
#         in bin/project_deploy for why a full "make it actually use the
#         tunnel" fix isn't done here (it would require changing
#         bin/scaffold_translation/bin/translation_audit themselves,
#         out of this script's own scope).
#   M28 — adding Google OAuth to an existing (already-deployed) stack
#         used to deadlock `make deploy`: the pre-deploy `mint-era`
#         bridge queried PublicSubnetId/BastionSubnetId outputs that
#         don't exist until the OAuth-adding `sam deploy` itself creates
#         them, so the pre-check failed before that deploy ever ran.
#   M29 — RDS master passwords may contain `%`, invalid in libpq's URI
#         parser; DATABASE_URL now carries a percent-encoded password.
RSpec.describe "bin/project_deploy — H13/H14/M28/M29 regressions", :io do
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

  # Generates the fixture for `basename` under a throwaway tmpdir and
  # returns the path bin/project_deploy actually wrote to
  # (<repo_root>/deploy/<basename> — always there regardless of where
  # the source domain lived, same as every other spec in this
  # directory).
  def self.generate!(basename, world_body, env_local: nil)
    Dir.mktmpdir do |dir|
      domain_dir = write_fixture(dir, basename, world_body, env_local: env_local)
      _stdout, stderr, status = Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir)
      status.success? or raise "bin/project_deploy failed: #{stderr}"
    end
    File.join(root, "deploy", basename)
  end

  # Extracts a Make target's recipe lines (tab/blank-prefixed lines
  # immediately following "target:\n"), same convention as
  # project_deploy_shared_rust_oauth_spec.rb's own `deploy_recipe_lines`.
  def self.recipe_lines(makefile, target)
    lines = makefile.lines
    start = lines.index { |l| l == "#{target}:\n" } or raise "no #{target}: target found in the generated Makefile"
    # Recipe lines proper start with a tab; a target's own explanatory
    # comments (e.g. mint_era_recipe's Shared-mode branch) are written
    # at column 0, with NO leading tab, sitting between "target:" and
    # the tab-prefixed recipe lines — still part of this target's own
    # block (Make just ignores them), so they're included here too.
    lines[(start + 1)..].take_while { |l| l == "\n" || l.start_with?("\t") || l.start_with?("#") }
  end

  # Splits a recipe's lines into independent shell chains — a "chain"
  # break happens after any line that does NOT end in a backslash
  # continuation (Make runs each such segment as its own separate shell
  # invocation). Comment lines are dropped; they sit between chains,
  # never inside one (bin/project_deploy's own documented rule — a
  # comment spliced mid-chain corrupts Make's assembly of it into one
  # shell script).
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

  # --- H13 -----------------------------------------------------------

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

  # --- H14 -------------------------------------------------------------

  describe "H14 — scaffold-translation/translation-audit refuse instead of silently running against the local DB" do
    before(:context) { @generated_dir = self.class.generate!("h14_own_fixture", <<~WORLD) }
      region "us-east-1"
    WORLD

    after(:context) { FileUtils.rm_rf(@generated_dir) }

    %w[scaffold-translation translation-audit].each do |target|
      it "#{target} refuses up front unless ALLOW_LOCAL_DB is set, before doing anything with AWS" do
        makefile = File.read(File.join(@generated_dir, "Makefile"))
        recipe = self.class.recipe_lines(makefile, target).join
        chains = self.class.shell_chains(self.class.recipe_lines(makefile, target))

        expect(recipe).to include("ALLOW_LOCAL_DB")
        expect(recipe).to include("REFUSING")
        expect(recipe).to match(/resolves its OWN database connection from .* \.world file, NOT from DATABASE_URL/)

        # The guard must be the recipe's OWN first chain (before the
        # "Looking up $(STACK)'s VPC/security group..." lookup, the
        # bastion stand-up, or the tunnel) — otherwise this is a fix
        # that reports the danger only after already causing it.
        expect(chains.first.join).to include("ALLOW_LOCAL_DB"),
                                     "the ALLOW_LOCAL_DB guard must be the FIRST thing #{target} does, not spliced in " \
                                     "after bastion/tunnel setup has already started"
      end

      it "#{target} really does refuse when actually run, and stops before touching the tunnel" do
        stdout, stderr, status = Open3.capture3("make", target, chdir: @generated_dir)
        expect(status.success?).to be(false), "#{target} should refuse (nonzero exit) without ALLOW_LOCAL_DB set"
        expect(stderr + stdout).to include("REFUSING")
      end
    end

    it "does not add the ALLOW_LOCAL_DB guard to migrate-console-settings (an app-owned script, not asserted env-blind)" do
      makefile = File.read(File.join(@generated_dir, "Makefile"))
      recipe = self.class.recipe_lines(makefile, "migrate-console-settings").join
      expect(recipe).not_to include("ALLOW_LOCAL_DB")
    end
  end

  # --- M28 -------------------------------------------------------------

  describe "M28 — adding Google OAuth to an existing stack no longer deadlocks the pre-deploy mint-era bridge" do
    before(:context) do
      # Built as a single-line string, not a heredoc whose own body
      # would put "GOOGLE_CLIENT_ID=..."/"GOOGLE_CLIENT_SECRET=..." at
      # column 0 of a spec.rb source line — load_hygiene_spec.rb's own
      # "no two spec files disagree about a top-level constant" check
      # scans for exactly that shape and would otherwise (falsely) flag
      # a collision with project_deploy_shared_rust_oauth_spec.rb's own
      # identical fixture content.
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
      # The dangerous branch (calling mint-era pre-deploy) must still be
      # reachable when the output IS already live — this isn't a
      # blanket skip.
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
          # Make strips a single leading "@" (its own "don't echo this"
          # marker) off the true first line before ever handing the
          # chain to the shell — replicate that before checking syntax.
          script = chain.join("\n").sub(/\A@/, "").gsub("$$", "$")
          _stdout, stderr, status = Open3.capture3("bash", "-n", stdin_data: script)
          expect(status.success?).to be(true),
                                     "invalid shell chain in #{generated_dir}'s deploy: recipe:\n#{stderr}\n---\n#{script}"
        end
      end
    end
  end

  # --- M29 -------------------------------------------------------------

  describe "M29 — the RDS master password is percent-encoded before it reaches a postgres:// URI" do
    before(:context) { @generated_dir = self.class.generate!("m29_own_fixture", <<~WORLD) }
      region "us-east-1"
    WORLD

    after(:context) { FileUtils.rm_rf(@generated_dir) }

    it "derives DB_PASS_URLENC via ERB::Util.url_encode and uses it (not raw DB_PASS) in every DATABASE_URL" do
      makefile = File.read(File.join(@generated_dir, "Makefile"))

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
      makefile = File.read(File.join(@generated_dir, "Makefile"))
      recipe = self.class.recipe_lines(makefile, "rename-schema").join

      expect(recipe).to include("PGPASSWORD=$$DB_PASS psql")
      expect(recipe).not_to include("PGPASSWORD=$$DB_PASS_URLENC")
    end

    it "actually percent-encodes a password containing % correctly (ERB::Util.url_encode, run for real)" do
      stdout, stderr, status = Open3.capture3("ruby", "-rerb", "-e", "print ERB::Util.url_encode(ARGV[0])", "ab%cd@ef/gh")
      expect(status.success?).to be(true), stderr
      expect(stdout).to eq("ab%25cd%40ef%2Fgh")
    end
  end
end
