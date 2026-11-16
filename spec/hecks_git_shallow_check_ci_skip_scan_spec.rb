require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/git_shallow_check"

# Builds a temporary checkout holding one file, for the scan to read.
module CiSkipScanFixtures
  ZSH_SKIP = <<~RUBY.freeze
    NO_ZSH = ("this machine has no /bin/zsh" unless File.executable?("/bin/zsh"))
    it "ends a tick", skip: NO_ZSH do
    end
  RUBY

  def checkout_with(path, body)
    dir = Dir.mktmpdir("ci-skip-scan")
    FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
    File.write(File.join(dir, path), body)
    (@dirs ||= []) << dir
    dir
  end

  def scan(body, paths = ["spec/beat_spec.rb"])
    described_class.call(checkout_with("spec/beat_spec.rb", body), paths)
  end
end

# The landing gate's static read of changed specs for a skip that only a runner without a macOS-only
# tool shows, which CI's skip backstop fails.
RSpec.describe Hecks::Adapters::GitShallowCheck::CiSkipScan do
  include CiSkipScanFixtures

  after { FileUtils.rm_rf(@dirs.to_a) }

  it "refuses a changed spec that skips where /bin/zsh is absent, naming the file and line" do
    expect { scan(CiSkipScanFixtures::ZSH_SKIP) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{CI skip scan \(static\).*spec/beat_spec\.rb:2 }m)
  end

  it "passes a spec that names zsh and does not skip" do
    expect(scan("system(\"/bin/zsh\")\n")).to be_nil
  end

  it "passes a skip that names no macOS-only tool" do
    expect(scan("it \"x\", skip: \"no node\" do\nend\n")).to be_nil
  end

  it "passes a spec tagged zsh_completion, which its CI job routes" do
    expect(scan("#{CiSkipScanFixtures::ZSH_SKIP}# zsh_completion\n")).to be_nil
  end

  it "ignores a changed spec that is not on disk" do
    expect(scan(CiSkipScanFixtures::ZSH_SKIP, ["spec/deleted_spec.rb"])).to be_nil
  end
end
