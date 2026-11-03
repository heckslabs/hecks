require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "hecks/release/runner"
require_relative "support/recording_commands"

# Drives Hecks::Release::Runner against a recorder instead of real git, gem,
# npm, curl or op, and a scratch directory instead of the repository. Nothing
# here touches the network, Postgres or a real registry.
RSpec.describe Hecks::Release::Runner, :aggregate_failures do
  # CI publishes after this many 15-second pauses; nil means it never does.
  let(:arrives_after) { 1 }
  let(:on_pause) { ->(_count) {} }

  def version = "9.9.9"

  def sha = "a" * 40

  def other_sha = "b" * 40

  def tag = "v#{version}"

  def root = (@root ||= Dir.mktmpdir("hecks-release-spec"))

  def commands = (@commands ||= ReleaseSpecSupport::RecordingCommands.new(sha: sha, version: version))

  def out = (@out ||= StringIO.new)

  def err = (@err ||= StringIO.new)

  def pauses = (@pauses ||= [])

  before do
    FileUtils.mkdir_p(File.join(root, "lib/hecks"))
    FileUtils.mkdir_p(File.join(root, "packages/hecks-client"))
    File.write(File.join(root, "lib/hecks/version.rb"), %(module Hecks\n  VERSION = "#{version}".freeze\nend\n))
    FileUtils.mkdir_p(File.join(root, "rust/host"))
    File.write(File.join(root, "rust/host/HECKS_RELEASE"), "#{version}\n")
    File.write(File.join(root, "packages/hecks-client/package.json"),
               JSON.generate("name" => "@hecks/client", "version" => version))
    File.write(File.join(root, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n\n## [#{version}] - 2026-01-01\n")
    FileUtils.mkdir_p(File.join(root, ".github/workflows"))
    File.write(File.join(root, ".github/workflows/publish-client.yml"), "name: Publish @hecks/client\n")
  end

  after { FileUtils.remove_entry(root) }

  def release(input: "", **flags)
    described_class.new(root: root, options: described_class::Options.new(**flags), commands: commands,
                        input: StringIO.new(input), out: out, err: err, **pacing).call
  end

  # The pause and clock the runner polls with: each pause is recorded, advances the clock, and
  # lets the scripted npm answer arrive once enough have passed.
  def pacing
    clock = 0
    pause = lambda do |seconds|
      pauses << seconds
      clock += seconds
      on_pause.call(pauses.size)
      published_npm! if arrives_after && pauses.size >= arrives_after
    end
    { pause: pause, now: -> { clock } }
  end

  # The vault's `op run` for the gem push and for the npm publish, by the env file each names.
  def gem_push = ["op", "run", "--env-file=release/gem_push.env"]

  def npm_publish = ["op", "run", "--env-file=#{File.join(root, "release/npm_publish.env")}"]

  def run_for(prefix) = commands.runs.find { |c| c.argv.first(prefix.size) == prefix }

  def gem_pushed? = commands.runs.any? { |c| c.argv.first(3) == gem_push }

  def npm_published? = commands.runs.any? { |c| c.argv.first(3) == npm_publish }

  def nothing_published?
    [commands.ran?("git", "push"), commands.ran?("git", "tag"), npm_published?, gem_pushed?].none?
  end

  def published_gem!
    commands.answer("curl", "-fsS", stdout: JSON.generate([{ "number" => version }, { "number" => "0.0.1" }]))
  end

  def published_npm!
    commands.answer("npm", "view", stdout: "#{version}\n")
  end

  def install_dependencies!
    FileUtils.mkdir_p(File.join(root, "packages/hecks-client/node_modules"))
  end

  def remove_workflow!
    FileUtils.rm_f(File.join(root, ".github/workflows/publish-client.yml"))
  end

  describe "preflight" do
    it "refuses off the release lane, naming the fix" do
      commands.answer("git", "rev-parse", "--abbrev-ref", "HEAD", stdout: "feature\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("on branch feature, not stable", "git checkout stable")
      expect(commands.runs).to be_empty
    end

    it "refuses on main, which takes pushes with no gate" do
      commands.answer("git", "rev-parse", "--abbrev-ref", "HEAD", stdout: "main\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("on branch main, not stable")
      expect(commands.runs).to be_empty
    end

    it "refuses when the release lane is behind its origin" do
      commands.answer("git", "rev-parse", "origin/stable", stdout: "#{other_sha}\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("is not origin/stable", "git pull --ff-only")
      expect(commands.runs).to be_empty
    end

    it "fetches origin before comparing" do
      release(yes: true, dry_run: true)

      expect(commands.argvs).to include(%w[git fetch origin])
    end

    it "refuses a dirty working tree" do
      commands.answer("git", "status", "--porcelain", stdout: " M lib/hecks/version.rb\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("uncommitted changes")
      expect(commands.runs).to be_empty
    end

    it "refuses when the client is at another version, in ReleaseGem's words" do
      File.write(File.join(root, "packages/hecks-client/package.json"), JSON.generate("version" => "9.9.8"))

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("packages/hecks-client is at 9.9.8 but Hecks::VERSION is #{version}; bump the package first.")
    end

    it "refuses when the Rust host's release file is at another version" do
      File.write(File.join(root, "rust/host/HECKS_RELEASE"), "9.9.8\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("rust/host/HECKS_RELEASE says \"9.9.8\" but Hecks::VERSION is #{version}")
    end

    it "refuses when the changelog has no heading for the version" do
      File.write(File.join(root, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("## [#{version}]")
      expect(commands.runs).to be_empty
    end

    it "refuses a missing tool, naming how to install it" do
      commands.answer("npm", "--version", success: false, stderr: "No such file or directory - npm")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("npm not found on PATH", "brew install node")
    end

    it "requires op for a real release" do
      commands.answer("op", "--version", success: false)

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("op not found on PATH", "brew install 1password-cli")
    end

    it "does not require op for a dry run" do
      commands.answer("op", "--version", success: false)

      expect(release(yes: true, dry_run: true)).to eq(0)
      expect(commands.argvs.map(&:first)).not_to include("op")
    end
  end

  describe "published state" do
    before { install_dependencies! }

    it "skips the gem when it is already on rubygems.org" do
      published_gem!

      expect(release(yes: true, npm_local: true)).to eq(0)
      expect(gem_pushed?).to be(false)
      expect(npm_published?).to be(true)
      expect(out.string).to include("hecks #{version} is already on rubygems.org; skipping.")
    end

    it "skips npm when the package is already published" do
      published_npm!

      expect(release(yes: true)).to eq(0)
      expect(gem_pushed?).to be(true)
      expect(npm_published?).to be(false)
      expect(out.string).to include("@hecks/client #{version} is already on npm; skipping.")
    end

    context "when both are already out" do
      before do
        published_gem!
        published_npm!
      end

      it "has nothing to publish, and still tags" do
        expect(release(yes: true)).to eq(0)
        expect(out.string).to include("Nothing to publish for #{version}.")
        expect([gem_pushed?, npm_published?]).to eq([false, false])
        expect(commands.ran?("git", "tag")).to be(true)
      end
    end

    it "refuses instead of guessing when npm fails for a reason other than a missing version" do
      commands.answer("npm", "view", success: false, stderr: "npm error network timeout\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("could not check npm")
      expect(commands.runs).to be_empty
    end

    it "refuses when rubygems cannot be listed" do
      commands.answer("curl", "-fsS", success: false, stderr: "curl: (6) Could not resolve host")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("could not list published hecks versions")
    end
  end

  describe "the tag" do
    before { install_dependencies! }

    it "creates an annotated tag at HEAD and pushes it when it is missing" do
      expect(release(yes: true)).to eq(0)

      expect(commands.argvs).to include(["git", "tag", "-a", tag, "-m", "Release #{version}", sha])
      expect(commands.argvs).to include(["git", "push", "origin", tag])
    end

    it "only pushes a local tag that is already at HEAD" do
      commands.answer("git", "rev-parse", "-q", "--verify", "refs/tags/#{tag}^{commit}", stdout: "#{sha}\n")

      expect(release(yes: true)).to eq(0)

      expect(commands.ran?("git", "tag")).to be(false)
      expect(commands.ran?("git", "push", "origin", tag)).to be(true)
    end

    it "does nothing when the tag is already on origin at HEAD, reading the peeled commit of an annotated tag" do
      commands.answer("git", "ls-remote", stdout: "#{other_sha}\trefs/tags/#{tag}\n#{sha}\trefs/tags/#{tag}^{}\n")

      expect(release(yes: true)).to eq(0)

      expect(commands.ran?("git", "tag")).to be(false)
      expect(commands.ran?("git", "push")).to be(false)
      expect(out.string).to include("Tag #{tag} is already on origin")
    end

    it "refuses a local tag that points elsewhere" do
      commands.answer("git", "rev-parse", "-q", "--verify", "refs/tags/#{tag}^{commit}", stdout: "#{other_sha}\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("already points at #{other_sha[0, 7]} locally")
      expect(commands.runs).to be_empty
    end

    it "refuses an origin tag that points elsewhere" do
      commands.answer("git", "ls-remote", stdout: "#{other_sha}\trefs/tags/#{tag}\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("already points at #{other_sha[0, 7]} on origin")
      expect(commands.runs).to be_empty
    end

    it "runs git with the repository-pinning variables unset" do
      release(yes: true)

      git_calls = commands.calls.select { |call| call.argv.first == "git" && call.argv[1] != "--version" }
      expect(git_calls).not_to be_empty
      expect(git_calls.map(&:env)).to all(eq(Hecks::Vendoring::GitEnvironment.clean))
      expect(git_calls.map(&:chdir)).to all(eq(root))
    end
  end

  describe "the order of the steps" do
    before { install_dependencies! }

    def steps
      commands.runs.map(&:argv).filter_map do |argv|
        if argv[0, 2] == %w[git tag] then :tag
        elsif argv[0, 2] == %w[git push] then :push
        elsif argv.first(3) == gem_push then :gem
        elsif argv.first(3) == npm_publish then :npm
        end
      end
    end

    it "tags, then publishes the gem, then publishes the package" do
      release(yes: true, npm_local: true)

      expect(steps).to eq(%i[tag push gem npm])
    end

    it "builds and pushes the gem in-process through the vault, from the repository root" do
      release(yes: true)
      push = run_for(gem_push)

      expect(push.argv).to eq([*gem_push, "--", "gem", "push", "hecks-#{version}.gem"])
      expect([run_for(%w[gem build hecks.gemspec]), push].map(&:chdir)).to eq([root, root])
      expect(commands.argvs.flatten).not_to include(File.join(root, "hecks publish_gem"))
    end
  end

  describe "installing the client's dependencies" do
    it "runs npm ci first when node_modules is missing" do
      release(yes: true, npm_local: true)

      expect(commands.argvs).to include(%w[npm ci])
    end

    it "does not run npm ci when node_modules is already there" do
      FileUtils.mkdir_p(File.join(root, "packages/hecks-client/node_modules"))
      release(yes: true, npm_local: true)

      expect(commands.argvs).not_to include(%w[npm ci])
    end
  end

  describe "the npm step" do
    before { install_dependencies! }

    def record_userconfig
      seen = {}
      commands.on_run(*npm_publish) do |argv|
        path = argv[argv.index("--userconfig") + 1]
        seen.update(path: path, content: File.read(path), mode: File.stat(path).mode & 0o777)
      end
      seen
    end

    def approval_notice
      "npm will print an approval link; open it and approve with your security key or passkey. " \
        "This step waits for you."
    end

    context "when publishing from here" do
      before do
        @seen = record_userconfig
        @code = release(yes: true, npm_only: true, npm_local: true)
      end

      it "succeeds" do
        expect(@code).to eq(0)
      end

      it "publishes through op run with a throwaway user config, from the package directory" do
        call = run_for(npm_publish)

        expect(call.argv).to eq(
          [*npm_publish, "--", "npm", "publish", "--access", "public", "--auth-type=web", "--userconfig", @seen[:path]]
        )
        expect(call.chdir).to eq(File.join(root, "packages/hecks-client"))
      end

      it "holds only a placeholder in the user config, readable by its owner alone" do
        expect(@seen[:content]).to eq("//registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}\n")
        expect(@seen[:mode]).to eq(0o600)
      end

      it "deletes the user config afterwards" do
        expect(File.exist?(@seen[:path])).to be(false)
      end

      it "uses npm's web authentication and does not capture the publish output, so the approval link shows" do
        captured = commands.calls.select { |c| c.kind == :capture }.map(&:argv)

        expect(run_for(npm_publish).argv).to include("--auth-type=web")
        expect(captured.none? { |argv| argv.include?("publish") || argv.include?("run") }).to be(true)
      end
    end

    it "deletes the user config when the publish fails" do
      path = nil
      commands.on_run(*npm_publish) { |argv| path = argv[argv.index("--userconfig") + 1] }
      commands.fail_run(*npm_publish)

      expect(release(yes: true, npm_only: true, npm_local: true)).to eq(1)
      expect(File.exist?(path)).to be(false)
    end

    it "says before publishing that npm will print an approval link and the step waits" do
      printed_before_publish = nil
      commands.on_run(*npm_publish) { printed_before_publish = out.string.dup }

      release(yes: true, npm_only: true, npm_local: true)

      expect(printed_before_publish).to include(approval_notice)
    end

    it "prints the exact resume command when npm fails after the gem is published" do
      commands.fail_run(*npm_publish)

      expect(release(yes: true, npm_local: true)).to eq(1)

      expect(gem_pushed?).to be(true)
      expect(err.string).to include("npm publish failed", "hecks publish --npm-only --npm-local --confirm")
    end

    it "does not offer to resume when the gem step is the one that failed" do
      commands.fail_run(*gem_push)

      expect(release(yes: true, npm_local: true)).to eq(1)
      expect(err.string).not_to include("--npm-only")
      expect(npm_published?).to be(false)
    end
  end

  describe "CI publishing the client (the default npm step)" do
    before { install_dependencies! }

    def resume_advice
      ["Timed out after 10 minutes", "gh run list --workflow publish-client.yml",
       "gh workflow run publish-client.yml -f tag=v#{version}", "hecks publish --npm-only --confirm",
       "hecks publish --npm-only --npm-local --confirm"]
    end

    context "when the tag is pushed" do
      before { @code = release(yes: true) }

      it "reports success" do
        expect(@code).to eq(0)
      end

      it "tells the person CI publishes from the tag" do
        expect(out.string).to include(
          "CI publishes @hecks/client #{version} from the tag (.github/workflows/publish-client.yml)",
          "@hecks/client #{version} is on npm."
        )
      end

      it "publishes nothing locally" do
        expect(npm_published?).to be(false)
        expect(commands.argvs.map { |argv| argv.first(2) }).not_to include(%w[npm publish], %w[npm ci])
      end
    end

    context "with the order recorded" do
      let(:order) { [] }
      let(:on_pause) { ->(_count) { order << :wait } }

      it "tags, then publishes the gem, then waits for CI" do
        commands.on_run("git", "push") { order << :push }
        commands.on_run(*gem_push) { order << :gem }

        release(yes: true)

        expect(order).to eq(%i[push gem wait])
      end
    end

    context "when it appears on the fourth check" do
      let(:arrives_after) { 4 }

      it "polls npm every 15 seconds until then" do
        expect(release(yes: true)).to eq(0)

        expect(pauses).to eq([15, 15, 15, 15])
      end
    end

    context "when a check fails on the way" do
      let(:arrives_after) { 3 }
      let(:on_pause) do
        lambda do |count|
          commands.answer("npm", "view", success: false, stderr: "npm error network timeout\n") if count == 1
        end
      end

      it "keeps polling" do
        expect(release(yes: true)).to eq(0)

        expect(pauses.size).to eq(3)
      end
    end

    context "when it never appears" do
      let(:arrives_after) { nil }

      before { @code = release(yes: true) }

      it "gives up with the gem published" do
        expect(@code).to eq(1)
        expect(gem_pushed?).to be(true)
      end

      it "gives up after 10 minutes of 15-second polls" do
        expect(pauses.size).to eq(40)
        expect(pauses.sum).to eq(600)
      end

      it "names the run to look at and how to resume" do
        expect(err.string).to include(*resume_advice)
      end
    end

    context "when it never appears and --no-wait is given" do
      let(:arrives_after) { nil }

      it "does not wait, and says how to check" do
        expect(release(yes: true, no_wait: true)).to eq(0)

        expect(pauses).to be_empty
        expect(out.string).to include("Not waiting (--no-wait)", "gh run list --workflow publish-client.yml")
      end
    end

    it "refuses before tagging when the workflow is not in the checkout, pointing at --npm-local" do
      remove_workflow!

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include(".github/workflows/publish-client.yml is not in this checkout", "--npm-local")
      expect(commands.runs).to be_empty
    end

    it "does not need the workflow for --npm-local" do
      remove_workflow!

      expect(release(yes: true, npm_local: true)).to eq(0)
      expect(npm_published?).to be(true)
    end

    it "does not need the workflow once npm already has the version" do
      remove_workflow!
      published_npm!

      expect(release(yes: true)).to eq(0)
    end

    it "does not need op when only waiting for CI" do
      commands.answer("op", "--version", success: false)

      expect(release(yes: true, npm_only: true)).to eq(0)
    end

    it "says in the publish question that CI publishes the client" do
      release(input: "y\ny\n")

      expect(out.string).to include("Publish hecks #{version} to rubygems.org (CI then publishes @hecks/client from the tag)?")
    end

    it "asks no publish question when only CI has anything left to do" do
      published_gem!

      expect(release(input: "y\n")).to eq(0)
      expect(out.string.scan("[y/N]").size).to eq(1)
    end

    it "on --dry-run says what it would wait for and waits for nothing" do
      expect(release(dry_run: true)).to eq(0)

      expect(out.string).to include("CI publishes @hecks/client #{version} from the tag", "Dry run: would wait up to 10 minutes")
      expect(pauses).to be_empty
      expect(commands.argvs.map { |argv| argv.first(2) }).not_to include(%w[npm publish])
      expect(commands.argvs.map(&:first)).not_to include("op")
    end
  end

  describe "the flags" do
    before { install_dependencies! }

    it "--gem-only leaves npm alone, even its published check" do
      expect(release(yes: true, gem_only: true)).to eq(0)

      expect(gem_pushed?).to be(true)
      expect(npm_published?).to be(false)
      expect(commands.argvs.map { |argv| argv.first(2) }).not_to include(%w[npm view])
    end

    it "--npm-only --npm-local publishes the package from here and leaves the gem alone" do
      expect(release(yes: true, npm_only: true, npm_local: true)).to eq(0)

      expect(gem_pushed?).to be(false)
      expect(npm_published?).to be(true)
    end

    it "--npm-only alone leaves the gem alone and waits for CI instead of publishing" do
      expect(release(yes: true, npm_only: true)).to eq(0)

      expect(gem_pushed?).to be(false)
      expect(npm_published?).to be(false)
      expect(pauses).not_to be_empty
      expect(out.string).to include("CI publishes @hecks/client #{version} from the tag")
    end

    it "rejects --npm-local with --gem-only, and --no-wait with --npm-local" do
      expect { described_class::Options.new(gem_only: true, npm_local: true) }.to raise_error(ArgumentError, /--npm-local/)
      expect { described_class::Options.new(no_wait: true, npm_local: true) }.to raise_error(ArgumentError, /--no-wait/)
    end

    it "rejects --gem-only with --npm-only" do
      expect { described_class::Options.new(gem_only: true, npm_only: true) }.to raise_error(ArgumentError, /cannot be combined/)
    end
  end

  describe "confirmation" do
    before { install_dependencies! }

    it "asks before the tag and before publishing, and proceeds on yes" do
      expect(release(input: "y\nyes\n", npm_local: true)).to eq(0)

      expect(out.string).to include("Create and push annotated tag #{tag}", "Publish hecks #{version} to rubygems.org and")
      expect(commands.ran?("git", "tag")).to be(true)
      expect(npm_published?).to be(true)
    end

    it "does nothing when the tag question is answered no" do
      expect(release(input: "n\n")).to eq(1)

      expect(commands.runs).to be_empty
      expect(err.string).to include("Aborted")
    end

    it "pushes nothing when the publish question is answered no, since the tag push starts CI's npm publish" do
      expect(release(input: "n\n")).to eq(1)

      expect(nothing_published?).to be(true)
      expect(err.string).to include("Aborted; nothing was published.")
    end

    it "keeps nothing pushed when the tag question is declined after the publish was agreed" do
      expect(release(input: "y\nn\n")).to eq(1)

      expect(commands.ran?("git", "push")).to be(false)
      expect(gem_pushed?).to be(false)
    end

    it "says in the tag question that the push makes CI publish the client" do
      published_gem!
      release(input: "n\n")

      expect(out.string).to include("CI then publishes @hecks/client #{version} to npm from the tag")
    end

    it "treats a closed input as no" do
      expect(release(input: "")).to eq(1)
      expect(commands.runs).to be_empty
    end

    it "asks nothing under --yes" do
      expect(release(yes: true)).to eq(0)
      expect(out.string).not_to include("[y/N]")
    end
  end

  describe "--dry-run" do
    before { install_dependencies! }

    def built_gem = File.join(root, "hecks-#{version}.gem")

    context "when the release is complete" do
      before do
        commands.on_run("gem", "build") { File.write(built_gem, "gem") }
        @code = release(dry_run: true, npm_local: true)
      end

      it "checks and builds without tagging, pushing or calling op" do
        expect(@code).to eq(0)
        expect(commands.argvs.map(&:first)).not_to include("op")
        expect(commands.ran?("git", "tag")).to be(false)
        expect(commands.ran?("git", "push")).to be(false)
      end

      it "builds the gem and dry-runs the npm publish, never publishing" do
        expect(commands.argvs).to include(%w[gem build hecks.gemspec])
        expect(commands.argvs).to include(%w[npm publish --dry-run --access public])
      end

      it "deletes the built gem" do
        expect(File.exist?(built_gem)).to be(false)
      end

      it "says what it would do and asks nothing" do
        expect(out.string).to include("Would create annotated tag #{tag}", "Would push #{tag} to origin", "Dry run complete")
        expect(out.string).not_to include("[y/N]")
      end

      it "runs npm publish --dry-run from the package directory, where it needs no auth" do
        call = run_for(%w[npm publish --dry-run])

        expect(call.chdir).to eq(File.join(root, "packages/hecks-client"))
        expect(call.argv).not_to include("--userconfig")
      end
    end

    it "deletes the built gem even when the build fails" do
      commands.on_run("gem", "build") { File.write(built_gem, "partial") }
      commands.fail_run("gem", "build")

      expect(release(dry_run: true)).to eq(1)
      expect(File.exist?(built_gem)).to be(false)
    end

    it "still refuses on a failed preflight" do
      commands.answer("git", "status", "--porcelain", stdout: "?? stray\n")

      expect(release(dry_run: true)).to eq(1)
      expect(err.string).to include("uncommitted changes")
    end
  end

  describe "secrets" do
    def call_values = commands.calls.flat_map { |call| call.argv + call.env.values.compact }

    it "are only referenced, never held, by release/npm_publish.env" do
      env_file = File.join(InMemoryDomain::ROOT, "release/npm_publish.env")
      assignments = File.readlines(env_file, chomp: true).reject { |line| line.strip.empty? || line.start_with?("#") }

      expect(assignments).not_to be_empty
      expect(assignments).to all(match(%r{\A[A-Z_]+="op://[^"]+"\z}))
    end

    context "with a release run" do
      before do
        install_dependencies!
        release(yes: true, npm_local: true)
      end

      it "never appear in an argument or environment value" do
        expect(call_values).not_to be_empty
        token = /npm_[A-Za-z0-9]{10,}|rubygems_[A-Za-z0-9]{10,}|_authToken=(?!\$\{NODE_AUTH_TOKEN\})/
        expect(call_values.grep(token)).to be_empty
      end

      it "are never passed through an environment value" do
        expect(commands.calls.flat_map { |call| call.env.values.compact }).to be_empty
      end
    end
  end
end
