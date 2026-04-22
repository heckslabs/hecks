# spec/hecks/runtime/runtime_shell_spec.rb
#
# Contract for Runtime#register_shell_adapter and Runtime#shell.
# Does not exercise the full boot path — see
# spec/integration/shell_adapter_end_to_end_spec.rb for that.
#
$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks"

RSpec.describe Hecks::Runtime do
  before do
    # Minimal domain: one aggregate, no behaviour. Hecks.load_bluebook
    # + Runtime.new gives us a working runtime without booting the
    # full pizzas example.
    @domain = Hecks.bluebook("ShellRt") do
      aggregate "Widget" do
        attribute :id, String
      end
    end
    Hecks.load_bluebook(@domain, skip_validation: true)
  end

  let(:runtime) { described_class.new(@domain) }

  let(:echo_adapter) do
    Hecksagon::Structure::ShellAdapter.new(
      name: :echo_args,
      command: "echo",
      args: ["{{msg}}"]
    )
  end

  describe "#register_shell_adapter" do
    it "stores the adapter by name" do
      runtime.register_shell_adapter(echo_adapter)
      expect(runtime.shell(:echo_args, msg: "hi").raw_stdout).to eq("hi\n")
    end
  end

  describe "#shell" do
    it "raises ConfigurationError for an unknown adapter" do
      expect { runtime.shell(:missing) }
        .to raise_error(Hecks::ConfigurationError, /no shell adapter/)
    end

    it "substitutes placeholders and dispatches through ShellDispatcher" do
      runtime.register_shell_adapter(echo_adapter)
      result = runtime.shell(:echo_args, msg: "hello")
      expect(result.output).to eq("hello\n")
      expect(result.exit_status).to eq(0)
    end

    it "accepts string names" do
      runtime.register_shell_adapter(echo_adapter)
      expect(runtime.shell("echo_args", msg: "x").raw_stdout).to eq("x\n")
    end
  end
end
