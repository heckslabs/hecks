require "spec_helper"
require "hecks"
require "hecks/cli/model_check"
require "tmpdir"

# `hecks model_check` names a malformed bluebook and exits 1; it never prints a stack trace.
RSpec.describe Hecks::CLI::ModelCheck do
  it "reports the refusal on stderr and exits 1" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "bad.bluebook"), <<~RUBY)
        Hecks.bluebook "Bad" do
          aggregate "Thing" do
            attribute :name, String
          end
        end
      RUBY

      expect do
        expect { described_class.call([dir], program: "hecks model_check") }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end.to output(/hecks model_check: Bad is not a well-formed bluebook/).to_stderr
    end
  end
end
