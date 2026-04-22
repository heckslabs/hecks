# spec/integration/shell_adapter_end_to_end_spec.rb
#
# Boots the examples/shell_adapter project through the full
# Hecks.boot(dir) path and exercises runtime.shell(:name, **attrs).
# Verifies that the bluebook + hecksagon on disk → boot wiring →
# Runtime#shell → ShellDispatcher chain works end-to-end.
#
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "hecks"

RSpec.describe "adapter :shell end-to-end" do
  let(:example_dir) { File.expand_path("../../examples/shell_adapter", __dir__) }

  around do |example|
    # Reset Hecks state between examples so last_domain / last_hecksagon
    # don't bleed across test runs.
    example.run
  end

  it "boots the example and dispatches :echo_args through runtime.shell" do
    runtime = Hecks.boot(example_dir)
    begin
      expect(runtime.domain.name).to eq("ShellDemo")

      result = runtime.shell(:echo_args, msg: "hello")
      expect(result.output).to eq("hello\n")
      expect(result.exit_status).to eq(0)
    ensure
      runtime.actor_system&.stop if runtime.respond_to?(:actor_system)
    end
  end

  it "dispatches :list_files with placeholder substitution and :lines parsing" do
    runtime = Hecks.boot(example_dir)
    begin
      result = runtime.shell(:list_files, dir: example_dir)
      expect(result.output).to include("shell_demo.rb")
      expect(result.output).to all(be_a(String))
    ensure
      runtime.actor_system&.stop if runtime.respond_to?(:actor_system)
    end
  end

  it "raises ConfigurationError for an unregistered name" do
    runtime = Hecks.boot(example_dir)
    begin
      expect { runtime.shell(:does_not_exist) }
        .to raise_error(Hecks::ConfigurationError, /no shell adapter/)
    ensure
      runtime.actor_system&.stop if runtime.respond_to?(:actor_system)
    end
  end
end
