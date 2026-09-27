require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "hecks/release/runner"
require_relative "support/recording_commands"

# Drives Hecks::Release::Runner against a recorder instead of real git, gem,
# npm, curl or op, and a scratch directory instead of the repository. Nothing
# here touches the network, Postgres or a real registry.
RSpec.describe Hecks::Release::Runner do
  let(:version) { "9.9.9" }
  let(:sha) { "a" * 40 }
  let(:other_sha) { "b" * 40 }
  let(:tag) { "v#{version}" }
  let(:root) { Dir.mktmpdir("hecks-release-spec") }
  let(:commands) { ReleaseSpecSupport::RecordingCommands.new(sha: sha, version: version) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  # CI publishes after this many 15-second pauses; nil means it never does.
  let(:arrives_after) { 1 }
  let(:pauses) { [] }
  let(:on_pause) { ->(_count) {} }

  before do
    FileUtils.mkdir_p(File.join(root, "lib/hecks"))
    FileUtils.mkdir_p(File.join(root, "packages/hecks-client"))
    File.write(File.join(root, "lib/hecks/version.rb"), %(module Hecks\n  VERSION = "#{version}".freeze\nend\n))
    File.write(File.join(root, "packages/hecks-client/package.json"),
               JSON.generate("name" => "@hecks/client", "version" => version))
    File.write(File.join(root, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n\n## [#{version}] - 2026-01-01\n")
    FileUtils.mkdir_p(File.join(root, ".github/workflows"))
    File.write(File.join(root, ".github/workflows/publish-client.yml"), "name: Publish @hecks/client\n")
  end

  after { FileUtils.remove_entry(root) }

  def release(input: "", **flags)
    options = described_class::Options.new(**flags)
    clock = 0
    pause = lambda do |seconds|
      pauses << seconds
      clock += seconds
      on_pause.call(pauses.size)
      published_npm! if arrives_after && pauses.size >= arrives_after
    end
    runner = described_class.new(root: root, options: options, commands: commands,
                                 input: StringIO.new(input), out: out, err: err,
                                 pause: pause, now: -> { clock })
    runner.call
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

  describe "preflight" do
    it "refuses off main, naming the fix" do
      commands.answer("git", "rev-parse", "--abbrev-ref", "HEAD", stdout: "feature\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("on branch feature, not main", "git checkout main")
      expect(commands.runs).to be_empty
    end

    it "refuses when main is behind origin/main" do
      commands.answer("git", "rev-parse", "origin/main", stdout: "#{other_sha}\n")

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("is not origin/main", "git pull --ff-only")
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

    it "refuses when the client is at another version, in bin/release_gem's words" do
      File.write(File.join(root, "packages/hecks-client/package.json"), JSON.generate("version" => "9.9.8"))

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("packages/hecks-client is at 9.9.8 but Hecks::VERSION is #{version}; bump the package first.")
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

    it "requires op for a real release but not for a dry run" do
      commands.answer("op", "--version", success: false)

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include("op not found on PATH", "brew install 1password-cli")

      err.truncate(0)
      commands.calls.clear
      expect(release(yes: true, dry_run: true)).to eq(0)
      expect(commands.argvs.map(&:first)).not_to include("op")
    end
  end

  describe "published state" do
    before { install_dependencies! }

    it "skips the gem when it is already on rubygems.org" do
      published_gem!

      expect(release(yes: true, npm_local: true)).to eq(0)
      expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(false)
      expect(commands.ran?("op", "run")).to be(true)
      expect(out.string).to include("hecks #{version} is already on rubygems.org; skipping.")
    end

    it "skips npm when the package is already published" do
      published_npm!

      expect(release(yes: true)).to eq(0)
      expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(true)
      expect(commands.ran?("op", "run")).to be(false)
      expect(out.string).to include("@hecks/client #{version} is already on npm; skipping.")
    end

    it "has nothing to publish once both are out, and still tags" do
      published_gem!
      published_npm!

      expect(release(yes: true)).to eq(0)
      expect(out.string).to include("Nothing to publish for #{version}.")
      expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(false)
      expect(commands.ran?("op", "run")).to be(false)
      expect(commands.ran?("git", "tag")).to be(true)
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
    it "tags, then publishes the gem, then publishes the package" do
      install_dependencies!
      release(yes: true, npm_local: true)

      steps = commands.runs.map(&:argv).filter_map do |argv|
        if argv[0, 2] == %w[git tag] then :tag
        elsif argv[0, 2] == %w[git push] then :push
        elsif argv[0] == File.join(root, "bin/release_gem") then :gem
        elsif argv[0, 2] == %w[op run] then :npm
        end
      end
      expect(steps).to eq(%i[tag push gem npm])
    end

    it "hands the gem to bin/release_gem unchanged, from the repository root" do
      install_dependencies!
      release(yes: true)

      call = commands.runs.find { |c| c.argv.first == File.join(root, "bin/release_gem") }
      expect(call.argv).to eq([File.join(root, "bin/release_gem")])
      expect(call.chdir).to eq(root)
    end

    it "runs npm ci first only when node_modules is missing" do
      release(yes: true, npm_local: true)
      expect(commands.argvs).to include(%w[npm ci])

      commands.calls.clear
      install_dependencies!
      release(yes: true, npm_local: true)
      expect(commands.argvs).not_to include(%w[npm ci])
    end
  end

  describe "the npm step" do
    before { install_dependencies! }

    it "publishes through op run with a throwaway user config that holds only a placeholder" do
      seen = {}
      commands.on_run("op", "run") do |argv|
        path = argv[argv.index("--userconfig") + 1]
        seen[:path] = path
        seen[:content] = File.read(path)
        seen[:mode] = File.stat(path).mode & 0o777
      end

      expect(release(yes: true, npm_only: true, npm_local: true)).to eq(0)

      call = commands.runs.find { |c| c.argv.first(2) == %w[op run] }
      expect(call.argv).to eq(
        ["op", "run", "--env-file=#{File.join(root, 'release/npm_publish.env')}", "--",
         "npm", "publish", "--access", "public", "--auth-type=web", "--userconfig", seen[:path]]
      )
      expect(call.chdir).to eq(File.join(root, "packages/hecks-client"))
      expect(seen[:content]).to eq("//registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}\n")
      expect(seen[:mode]).to eq(0o600)
      expect(File.exist?(seen[:path])).to be(false)
    end

    it "deletes the user config when the publish fails" do
      path = nil
      commands.on_run("op", "run") { |argv| path = argv[argv.index("--userconfig") + 1] }
      commands.fail_run("op", "run")

      expect(release(yes: true, npm_only: true, npm_local: true)).to eq(1)
      expect(File.exist?(path)).to be(false)
    end

    it "uses npm's web authentication and does not capture the publish output, so the approval link shows" do
      release(yes: true, npm_only: true, npm_local: true)

      publish = commands.runs.find { |c| c.argv.first(2) == %w[op run] }
      expect(publish.argv).to include("--auth-type=web")
      captured = commands.calls.select { |c| c.kind == :capture }.map(&:argv)
      expect(captured.none? { |argv| argv.include?("publish") || argv.include?("run") }).to be(true)
    end

    it "says before publishing that npm will print an approval link and the step waits" do
      printed_before_publish = nil
      commands.on_run("op", "run") { printed_before_publish = out.string.dup }

      release(yes: true, npm_only: true, npm_local: true)

      expect(printed_before_publish).to include(
        "npm will print an approval link; open it and approve with your security key or passkey. " \
        "This step waits for you."
      )
    end

    it "prints the exact resume command when npm fails after the gem is published" do
      commands.fail_run("op", "run")

      expect(release(yes: true, npm_local: true)).to eq(1)

      expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(true)
      expect(err.string).to include("npm publish failed", "bin/release --npm-only --npm-local")
    end

    it "does not offer to resume when the gem step is the one that failed" do
      commands.fail_run(File.join(root, "bin/release_gem"))

      expect(release(yes: true, npm_local: true)).to eq(1)
      expect(err.string).not_to include("--npm-only")
      expect(commands.ran?("op", "run")).to be(false)
    end
  end

  describe "CI publishing the client (the default npm step)" do
    before { install_dependencies! }

    it "tells the person CI publishes from the tag, publishes nothing locally, and reports success" do
      expect(release(yes: true)).to eq(0)

      expect(out.string).to include(
        "CI publishes @hecks/client #{version} from the tag (.github/workflows/publish-client.yml)",
        "@hecks/client #{version} is on npm."
      )
      expect(commands.ran?("op", "run")).to be(false)
      expect(commands.argvs.map { |argv| argv.first(2) }).not_to include(%w[npm publish], %w[npm ci])
    end

    context "with the order recorded" do
      let(:order) { [] }
      let(:on_pause) { ->(_count) { order << :wait } }

      it "tags, then publishes the gem, then waits for CI" do
        commands.on_run("git", "push") { order << :push }
        commands.on_run(File.join(root, "bin/release_gem")) { order << :gem }

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

      it "gives up after 10 minutes with the run to look at and how to resume" do
        expect(release(yes: true)).to eq(1)

        expect(pauses.size).to eq(40)
        expect(pauses.sum).to eq(600)
        expect(err.string).to include(
          "Timed out after 10 minutes", "gh run list --workflow publish-client.yml",
          "gh workflow run publish-client.yml -f tag=v#{version}", "bin/release --npm-only", "bin/release --npm-only --npm-local"
        )
        expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(true)
      end

      it "does not wait under --no-wait, and says how to check" do
        expect(release(yes: true, no_wait: true)).to eq(0)

        expect(pauses).to be_empty
        expect(out.string).to include("Not waiting (--no-wait)", "gh run list --workflow publish-client.yml")
      end
    end

    it "refuses before tagging when the workflow is not in the checkout, pointing at --npm-local" do
      FileUtils.rm_f(File.join(root, ".github/workflows/publish-client.yml"))

      expect(release(yes: true)).to eq(1)
      expect(err.string).to include(".github/workflows/publish-client.yml is not in this checkout", "--npm-local")
      expect(commands.runs).to be_empty
    end

    it "does not need the workflow for --npm-local" do
      FileUtils.rm_f(File.join(root, ".github/workflows/publish-client.yml"))

      expect(release(yes: true, npm_local: true)).to eq(0)
      expect(commands.ran?("op", "run")).to be(true)
    end

    it "does not need the workflow once npm already has the version" do
      FileUtils.rm_f(File.join(root, ".github/workflows/publish-client.yml"))
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

      expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(true)
      expect(commands.ran?("op", "run")).to be(false)
      expect(commands.argvs.map { |argv| argv.first(2) }).not_to include(%w[npm view])
    end

    it "--npm-only --npm-local publishes the package from here and leaves the gem alone" do
      expect(release(yes: true, npm_only: true, npm_local: true)).to eq(0)

      expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(false)
      expect(commands.ran?("op", "run")).to be(true)
    end

    it "--npm-only alone leaves the gem alone and waits for CI instead of publishing" do
      expect(release(yes: true, npm_only: true)).to eq(0)

      expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(false)
      expect(commands.ran?("op", "run")).to be(false)
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
      expect(commands.ran?("op", "run")).to be(true)
    end

    it "does nothing when the tag question is answered no" do
      expect(release(input: "n\n")).to eq(1)

      expect(commands.runs).to be_empty
      expect(err.string).to include("Aborted")
    end

    it "does not publish when the publish question is answered no, but keeps the tag" do
      expect(release(input: "y\nn\n")).to eq(1)

      expect(commands.ran?("git", "push", "origin", tag)).to be(true)
      expect(commands.ran?("op", "run")).to be(false)
      expect(commands.ran?(File.join(root, "bin/release_gem"))).to be(false)
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
    it "checks and builds but never tags, pushes, publishes or calls op" do
      install_dependencies!
      commands.on_run("gem", "build") { File.write(File.join(root, "hecks-#{version}.gem"), "gem") }

      expect(release(dry_run: true, npm_local: true)).to eq(0)

      expect(commands.argvs.map(&:first)).not_to include("op", File.join(root, "bin/release_gem"))
      expect(commands.ran?("git", "tag")).to be(false)
      expect(commands.ran?("git", "push")).to be(false)
      expect(commands.argvs).to include(%w[gem build hecks.gemspec])
      expect(commands.argvs).to include(%w[npm publish --dry-run --access public])
      expect(File.exist?(File.join(root, "hecks-#{version}.gem"))).to be(false)
      expect(out.string).to include("Would create annotated tag #{tag}", "Would push #{tag} to origin", "Dry run complete")
      expect(out.string).not_to include("[y/N]")
    end

    it "runs npm publish --dry-run from the package directory, where it needs no auth" do
      install_dependencies!
      release(dry_run: true, npm_local: true)

      call = commands.runs.find { |c| c.argv.first(3) == %w[npm publish --dry-run] }
      expect(call.chdir).to eq(File.join(root, "packages/hecks-client"))
      expect(call.argv).not_to include("--userconfig")
    end

    it "deletes the built gem even when the build fails" do
      install_dependencies!
      commands.on_run("gem", "build") { File.write(File.join(root, "hecks-#{version}.gem"), "partial") }
      commands.fail_run("gem", "build")

      expect(release(dry_run: true)).to eq(1)
      expect(File.exist?(File.join(root, "hecks-#{version}.gem"))).to be(false)
    end

    it "still refuses on a failed preflight" do
      commands.answer("git", "status", "--porcelain", stdout: "?? stray\n")

      expect(release(dry_run: true)).to eq(1)
      expect(err.string).to include("uncommitted changes")
    end
  end

  describe "secrets" do
    it "are only referenced, never held, by release/npm_publish.env" do
      env_file = File.join(InMemoryDomain::ROOT, "release/npm_publish.env")
      assignments = File.readlines(env_file, chomp: true).reject { |line| line.strip.empty? || line.start_with?("#") }

      expect(assignments).not_to be_empty
      expect(assignments).to all(match(%r{\A[A-Z_]+="op://[^"]+"\z}))
    end

    it "never appear in an argument or environment value" do
      install_dependencies!
      release(yes: true, npm_local: true)

      values = commands.calls.flat_map { |call| call.argv + call.env.values.compact }
      expect(values).not_to be_empty
      expect(values.grep(/npm_[A-Za-z0-9]{10,}|rubygems_[A-Za-z0-9]{10,}|_authToken=(?!\$\{NODE_AUTH_TOKEN\})/)).to be_empty
      expect(commands.calls.flat_map { |call| call.env.values.compact }).to be_empty
    end
  end
end
