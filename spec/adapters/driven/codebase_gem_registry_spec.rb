require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/codebase/gem_registry"
require_relative "../../release/support/recording_commands"

RSpec.describe Hecks::Adapters::Codebase::GemRegistry do
  let(:root) { Dir.mktmpdir("hecks-gem-registry") }
  let(:commands) { ReleaseSpecSupport::RecordingCommands.new(sha: "a" * 40, version: "1.0.0") }
  let(:registry) { described_class.new(root: root, commands: commands) }
  let(:refusal) { Hecks::Release::Runner::Refusal }
  let(:gem_file) { File.join(root, "hecks-1.0.0.gem") }

  after { FileUtils.remove_entry(root) }

  it "lists a version as published when RubyGems does", :aggregate_failures do
    commands.answer("curl", "-fsS", stdout: JSON.generate([{ "number" => "1.0.0" }]))

    expect(registry.published?("1.0.0")).to be(true)
    expect(registry.published?("2.0.0")).to be(false)
    expect(commands.argvs.first).to eq(["curl", "-fsS", described_class::VERSIONS_URL])
  end

  it "refuses when RubyGems cannot be reached, and when it answers with something else", :aggregate_failures do
    commands.answer("curl", "-fsS", success: false, stderr: "curl: (6) Could not resolve host")
    expect { registry.published?("1.0.0") }.to raise_error(refusal, /could not list published hecks versions/)

    commands.answer("curl", "-fsS", stdout: "<html>")
    expect { registry.published?("1.0.0") }.to raise_error(refusal, /something other than a version list/)
  end

  it "builds the gem to prove it builds, and deletes the file", :aggregate_failures do
    commands.on_run("gem", "build") { File.write(gem_file, "gem") }

    registry.build_only!("1.0.0")

    expect(commands.argvs).to eq([%w[gem build hecks.gemspec]])
    expect(File).not_to exist(gem_file)
  end

  it "builds, pushes through the vault with the push key, and deletes the file", :aggregate_failures do
    commands.on_run("gem", "build") { File.write(gem_file, "gem") }

    registry.push!("1.0.0")

    expect(commands.argvs).to eq([%w[gem build hecks.gemspec],
                                  %w[op run --env-file=release/gem_push.env -- gem push hecks-1.0.0.gem]])
    expect(File).not_to exist(gem_file)
  end

  it "deletes the file even when the push fails", :aggregate_failures do
    commands.on_run("gem", "build") { File.write(gem_file, "gem") }
    commands.fail_run("op")

    expect { registry.push!("1.0.0") }.to raise_error(Hecks::Release::Runner::CommandFailed)
    expect(File).not_to exist(gem_file)
  end
end
