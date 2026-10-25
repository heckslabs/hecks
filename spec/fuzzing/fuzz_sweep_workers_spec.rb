require "spec_helper"
require "etc"
require "hecks/tools"
require "hecks/tools/fuzz_sweep"
require "hecks/fuzzing"

# How many children a sweep runs at once, and which Postgres schema each one fuzzes in.
RSpec.describe Hecks::Tools::FuzzSweep, :aggregate_failures do
  let(:boot) { Hecks::Fuzzing::IsolatedBoot }
  let(:schema_env) { Hecks::Fuzzing::IsolatedBoot::FUZZ_SCHEMA_ENV }

  describe "the worker count" do
    it "takes the number the caller types, whatever the adapter" do
      options = described_class.parse(%w[--adapter postgres --workers 3])

      expect(described_class.worker_count(options)).to eq(3)
    end

    it "gives a Postgres sweep up to four workers off macOS" do
      stub_const("RUBY_PLATFORM", "x86_64-linux")

      expect(described_class.worker_count({ adapter: :postgres })).to eq([Etc.nprocessors, 4].min)
    end

    it "gives a Postgres sweep one worker on macOS, where libpq crashes in a forked child" do
      stub_const("RUBY_PLATFORM", "arm64-darwin24")

      expect(described_class.worker_count({ adapter: :postgres })).to eq(1)
    end

    it "gives every other adapter a worker per core" do
      expect(described_class.worker_count({ adapter: :memory })).to eq(Etc.nprocessors)
    end
  end

  describe "the scratch schema of a Postgres boot" do
    before do
      boot.instance_variable_set(:@fuzz_schema_cleanups, nil)
      allow(boot).to receive(:at_exit).and_return(proc {})
    end

    after { ENV.delete(schema_env) }

    def exit_hook_for(schema)
      hook = nil
      allow(boot).to receive(:at_exit) { |&block| hook = block }
      boot.drop_at_exit("hecks_fuzz", schema)
      hook
    end

    it "is this process's own unless the process names one, so parallel workers never share it" do
      ENV.delete(schema_env)

      expect(boot.scratch_schema("hecks_fuzz")).to eq("hecks_fuzz_#{Process.pid}")
    end

    it "is dropped only by the process that asked for it, not a forked child inheriting the hook" do
      allow(boot).to receive(:drop_schema_quietly)
      hook = exit_hook_for("hecks_fuzz_4242")
      allow(Process).to receive(:pid).and_return(Process.pid + 1)
      hook.call

      expect(boot).not_to have_received(:drop_schema_quietly)
    end

    it "is the schema a pool child names, dropped once when the child exits" do
      ENV[schema_env] = "hecks_fuzz_4242"
      2.times { boot.scratch_schema("hecks_fuzz") }

      expect(boot).to have_received(:at_exit).once
    end

    it "names the schema a pool child asked for" do
      ENV[schema_env] = "hecks_fuzz_4242"

      expect(boot.scratch_schema("hecks_fuzz")).to eq("hecks_fuzz_4242")
    end
  end
end
