# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

# The Hecks domain (lib/hecks/hecks/) operates on the runtime but never sits in a client's dispatch
# (ADR 0080, section 5). Each check runs in a fresh process, so `$LOADED_FEATURES` is only what
# that path itself loaded. The launcher boots pizzas on its Memory hecksagon, so no database
# has to be reachable.
RSpec.describe "the Hecks domain stays out of a client's runtime" do
  root = File.expand_path("..", __dir__)

  define_method(:probe) do |script|
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", script, chdir: root)
    raise "probe failed: #{err}" unless status.success?

    JSON.parse(out.lines.last)
  end

  # The pattern, as Ruby source, a probe greps `$LOADED_FEATURES` with.
  HECKS_DOMAIN_PATTERN = "%r{/lib/hecks/hecks/}"

  REQUIRE_PROBE = <<~RUBY.freeze
    require "hecks"
    require "json"
    puts JSON.generate(loaded: $LOADED_FEATURES.grep(#{HECKS_DOMAIN_PATTERN}))
  RUBY

  LAUNCHER_PROBE = <<~RUBY.freeze
    require "hecks"
    require "json"
    runtime = Hecks.boot_files(
      [File.join(Dir.pwd, "examples/pizzas/bluebook/pizzas.bluebook"),
       File.join(Dir.pwd, "examples/pizzas/pizzas_behaviors.hecksagon")],
      install_driving: false
    )
    Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: ["create_pizza", "name=Margherita"], program: "pizzas")
    puts JSON.generate(loaded: $LOADED_FEATURES.grep(#{HECKS_DOMAIN_PATTERN}), chapters: runtime.registry.bluebooks.keys)
  RUBY

  it "is never loaded by `require \"hecks\"`" do
    expect(probe(REQUIRE_PROBE)["loaded"]).to be_empty
  end

  it "is never loaded by a client launcher's boot and dispatch, and is not in its registry", :aggregate_failures do
    result = probe(LAUNCHER_PROBE)

    expect(result["loaded"]).to be_empty
    expect(result["chapters"]).not_to include("Hecks")
  end
end
