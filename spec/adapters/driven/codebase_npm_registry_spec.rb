require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/codebase/npm_registry"
require_relative "../../release/support/recording_commands"

RSpec.describe Hecks::Adapters::Codebase::NpmRegistry do
  let(:root) { Dir.mktmpdir("hecks-npm-registry") }
  let(:commands) { ReleaseSpecSupport::RecordingCommands.new(sha: "a" * 40, version: "1.0.0") }
  let(:registry) { described_class.new(root: root, commands: commands) }
  let(:package_dir) { File.join(root, "packages/hecks-client") }

  before { FileUtils.mkdir_p(package_dir) }

  after { FileUtils.remove_entry(root) }

  it "lists a version as published when npm does, and as not when npm says 404" do
    expect(registry.published?("1.0.0")).to be(false)

    commands.answer("npm", "view", stdout: "1.0.0\n")

    expect(registry.published?("1.0.0")).to be(true)
  end

  it "refuses for any other npm failure" do
    commands.answer("npm", "view", success: false, stderr: "npm error network timeout\n")

    expect { registry.published?("1.0.0") }.to raise_error(Hecks::Release::Runner::Refusal, /could not check npm/)
  end

  it "installs the dependencies in the package's directory, and knows when they are there" do
    expect(registry).not_to be_installed

    registry.install!
    FileUtils.mkdir_p(File.join(package_dir, "node_modules"))

    expect(commands.runs.first.argv).to eq(%w[npm ci])
    expect(commands.runs.first.chdir).to eq(package_dir)
    expect(registry).to be_installed
  end

  it "packs without publishing for a dry run" do
    registry.dry_publish!

    expect(commands.argvs).to eq([%w[npm publish --dry-run --access public]])
  end

  it "publishes through the vault with a one-use npmrc that reads the token from the environment" do
    seen = nil
    commands.on_run("op") do |argv|
      path = argv[argv.index("--userconfig") + 1]
      seen = { path: path, content: File.read(path), mode: File.stat(path).mode & 0o777 }
    end

    registry.publish!

    env_file = "--env-file=#{File.join(root, "release/npm_publish.env")}"
    expect(commands.runs.first.argv.first(6)).to eq(["op", "run", env_file, "--", "npm", "publish"])
    expect(seen[:content]).to eq("//registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}\n")
    expect(seen[:mode]).to eq(0o600)
    expect(File).not_to exist(seen[:path])
  end
end
