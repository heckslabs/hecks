require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/operation_run"

# `hecks run` saves through whatever the domain binds, and `HECKS_ENVIRONMENT` only changes that
# for a domain that ships the overlay. A name with no overlay must be said, not ignored.
RSpec.describe Hecks::Adapters::OperationRun, ".unmatched_environment" do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  def write_overlay(name)
    FileUtils.mkdir_p(File.join(dir, "environments"))
    File.write(File.join(dir, "environments", "#{name}.world"), "")
  end

  it "names an environment the domain has no overlay for" do
    expect(described_class.unmatched_environment(dir,
                                                 "memory")).to match(/HECKS_ENVIRONMENT=memory has no overlay in .*environments/)
  end

  it "stays quiet when the domain ships the overlay" do
    write_overlay("memory")

    expect(described_class.unmatched_environment(dir, "memory")).to be_nil
  end

  it "stays quiet when no environment is named" do
    expect(described_class.unmatched_environment(dir, " ")).to be_nil
  end
end
