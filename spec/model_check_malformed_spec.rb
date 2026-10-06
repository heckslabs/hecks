require "spec_helper"
require "hecks"
require "hecks/cli/model_check"
require "tmpdir"

# `hecks model_check` names a malformed bluebook and exits 1; it never prints a stack trace.
RSpec.describe Hecks::CLI::ModelCheck do
  MALFORMED_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Bad" do
      aggregate "Thing" do
        attribute :name, String
      end
    end
  RUBY

  # Yields a scratch directory holding the malformed bluebook.
  def with_malformed_bluebook
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "bad.bluebook"), MALFORMED_BLUEBOOK)
      yield dir
    end
  end

  # The status the check exits with, or nil when it returns without exiting.
  def exit_status_of(dir)
    described_class.call([dir], program: "hecks model_check")
    nil
  rescue SystemExit => e
    e.status
  end

  it "reports the refusal on stderr and exits 1", :aggregate_failures do
    with_malformed_bluebook do |dir|
      status = nil
      expect { status = exit_status_of(dir) }.to output(/hecks model_check: Bad is not a well-formed bluebook/).to_stderr
      expect(status).to eq(1)
    end
  end
end
