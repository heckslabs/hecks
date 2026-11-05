require "spec_helper"

# The Onboarding example is first-run setup of Hecks on one machine. Its MachineProbe adapter reads
# the machine; here the machine is a stand-in, so the spec says the same on any host. The flow boots
# the real bluebook and hecksagon, and the probes answer through the adapter the way a run does.
RSpec.describe "the Onboarding example" do
  let(:dir) { File.expand_path("../examples/onboarding/bluebook", __dir__) }
  let(:ok) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:failed) { instance_double(Process::Status, success?: false, exitstatus: 1) }

  def load_probe
    load File.join(dir, "adapters", "machine_probe.rb")
    Hecks::Adapters::MachineProbe.new
  end

  # Answers each command the probe runs from a table of `[output, status]`, by command name.
  def machine(answers)
    allow(Open3).to receive(:capture2e) do |*command|
      answers.fetch(command.first) { raise Errno::ENOENT, command.first }
    end
  end

  describe "the MachineProbe adapter" do
    subject(:probe) { load_probe }

    it "reads the Ruby version off the ruby on the path" do
      machine("ruby" => ["3.4.1", ok])
      expect(probe.read_ruby_version(machine: { value: "m1" })).to eq(machine: "m1", major: 3, minor: 4)
    end

    it "refuses a ruby that answers no version" do
      machine("ruby" => ["not a version", ok])
      expect { probe.read_ruby_version(machine: "m1") }.to raise_error(Hecks::Runtime::GivenNotMet, /not a version/)
    end

    it "refuses when there is no ruby at all" do
      machine({})
      expect { probe.read_ruby_version(machine: "m1") }.to raise_error(Hecks::Runtime::GivenNotMet, /cannot run ruby/)
    end

    it "ignores the rest of the record the runtime passes along" do
      machine("gem" => ["true", ok])
      expect(probe.find_hecks_gem(machine: "m1", status: "ruby_checked")).to eq(machine: "m1", exit_code: 0)
    end

    it "says how to install the gem when it is missing" do
      machine("gem" => ["false", failed])
      expect { probe.find_hecks_gem(machine: "m1") }.to raise_error(Hecks::Runtime::GivenNotMet, /gem install hecks/)
    end

    it "answers the launcher's exit code when it lists its commands" do
      machine("hecks" => ["commands...", ok])
      expect(probe.list_launcher_commands(machine: "m1")).to eq(machine: "m1", exit_code: 0)
    end

    it "refuses a launcher that exits non-zero" do
      machine("hecks" => ["", failed])
      expect { probe.list_launcher_commands(machine: "m1") }.to raise_error(Hecks::Runtime::GivenNotMet, /exited 1/)
    end

    it "refuses a launcher that exits 0 and says nothing" do
      machine("hecks" => ["  \n", ok])
      expect { probe.list_launcher_commands(machine: "m1") }.to raise_error(Hecks::Runtime::GivenNotMet, /nothing/)
    end
  end

  describe "the six steps" do
    # The runtime resolves the probe by constant, so the flow loads it before it boots.
    before do
      load_probe
      machine("ruby" => ["3.4.1", ok], "gem" => ["true", ok], "hecks" => ["commands", ok])
      app
    end

    let(:app) { Hecks.boot(dir, environment: "memory") }
    let(:status) { -> { Onboarding::Onboarding.all.map(&:status) } }

    def step(verb, with = {}) = app.dispatch("Onboarding::Onboarding.#{verb}", to: "m1", with: with)

    # Runs the steps in order, up to and including the named one.
    def walk_to(last)
      Onboarding::Onboarding.request_onboarding!(machine: "m1")
      [["RequestGemCheck", {}], ["RequestLauncherCheck", {}],
       ["OpenExample", { exit_code: 0, domain: "Pizzas" }],
       ["ScaffoldDomain", { via: "init", exit_code: 0 }],
       ["RunChecks", { model_check: "clean", smoke_test: "clean" }]].each do |verb, with|
        step(verb, with)
        break if verb == last
      end
    end

    it "settles the Ruby step from the Ruby probe" do
      Onboarding::Onboarding.request_onboarding!(machine: "m1")
      expect(status.call).to eq(["ruby_checked"])
    end

    it "settles the gem step from the gem probe" do
      walk_to("RequestGemCheck")
      expect(status.call).to eq(["gem_installed"])
    end

    it "settles the launcher step from the launcher probe" do
      walk_to("RequestLauncherCheck")
      expect(status.call).to eq(["launcher_checked"])
    end

    it "walks a machine from fresh to checks_run" do
      walk_to("RunChecks")
      expect(status.call).to eq(["checks_run"])
    end

    # Asks for the last step straight after the first, which the lifecycle refuses.
    #
    # @return [StandardError, nil] the refusal, or nil when the step was wrongly accepted
    def run_checks_early
      Onboarding::Onboarding.request_onboarding!(machine: "m1")
      step("RunChecks", model_check: "clean", smoke_test: "clean")
      nil
    rescue StandardError => e
      e
    end

    it "refuses a step asked for before the one it follows" do
      expect(run_checks_early).to be_a(StandardError)
    end

    it "keeps the earlier status after a refused step" do
      run_checks_early
      expect(status.call).to eq(["ruby_checked"])
    end

    it "stops at ruby_checked when the machine has no gem" do
      machine("ruby" => ["3.4.1", ok], "gem" => ["false", failed])
      Onboarding::Onboarding.request_onboarding!(machine: "m1")
      step("RequestGemCheck")
      expect(status.call).to eq(["ruby_checked"])
    end

    it "refuses a Ruby below 3.2" do
      machine("ruby" => ["3.1.4", ok])
      Onboarding::Onboarding.request_onboarding!(machine: "m1")
      expect(status.call).to eq(["fresh"])
    end
  end
end
