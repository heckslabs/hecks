require "spec_helper"
require "tmpdir"
require "hecks/cli/run"

# `hecks run` saves through whatever the domain binds, and `HECKS_ENVIRONMENT` only changes that
# for a domain that ships the overlay. A name with no overlay must be said, not ignored.
RSpec.describe Hecks::CLI::Run, ".warn_unmatched_environment" do
  let(:dir) { Dir.mktmpdir }

  around do |example|
    saved = ENV.fetch("HECKS_ENVIRONMENT", nil)
    example.run
  ensure
    ENV["HECKS_ENVIRONMENT"] = saved
    FileUtils.rm_rf(dir)
  end

  def write_overlay(name)
    FileUtils.mkdir_p(File.join(dir, "environments"))
    File.write(File.join(dir, "environments", "#{name}.world"), "")
  end

  it "names an environment the domain has no overlay for" do
    ENV["HECKS_ENVIRONMENT"] = "memory"

    expect { described_class.warn_unmatched_environment(dir) }
      .to output(/HECKS_ENVIRONMENT=memory has no overlay in .*environments/).to_stderr
  end

  it "stays quiet when the domain ships the overlay" do
    ENV["HECKS_ENVIRONMENT"] = "memory"
    write_overlay("memory")

    expect { described_class.warn_unmatched_environment(dir) }.not_to output.to_stderr
  end

  it "stays quiet when no environment is named" do
    ENV["HECKS_ENVIRONMENT"] = " "

    expect { described_class.warn_unmatched_environment(dir) }.not_to output.to_stderr
  end
end
