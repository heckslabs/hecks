# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

# The Hecks domain (lib/hecks/hecks/) operates on the runtime but never sits in a client's dispatch
# (ADR 0080, section 5). Each check runs in a fresh process, so `$LOADED_FEATURES` is only what
# that path itself loaded.
RSpec.describe "the Hecks domain stays out of a client's runtime" do
  root = File.expand_path("..", __dir__)

  define_method(:probe) do |script|
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", script, chdir: root)
    raise "probe failed: #{err}" unless status.success?

    JSON.parse(out.lines.last)
  end

  # The pattern, as Ruby source, a probe greps `$LOADED_FEATURES` with.
  def hecks_domain = "%r{/lib/hecks/hecks/}"

  it "is never loaded by `require \"hecks\"`" do
    result = probe(<<~RUBY)
      require "hecks"
      require "json"
      puts JSON.generate(loaded: $LOADED_FEATURES.grep(#{hecks_domain}))
    RUBY

    expect(result["loaded"]).to be_empty
  end

  it "is never loaded by a client launcher's boot and dispatch, and is not in its registry" do
    result = probe(<<~RUBY)
      require "hecks"
      require "json"
      runtime = Hecks.boot(File.join(Dir.pwd, "examples/pizzas"), install_facade: false)
      Hecks::Facade::CliRunner.call(runtime: runtime, argv: ["create_pizza", "name=Margherita"], program: "pizzas")
      puts JSON.generate(loaded: $LOADED_FEATURES.grep(#{hecks_domain}), chapters: runtime.registry.bluebooks.keys)
    RUBY

    expect(result["loaded"]).to be_empty
    expect(result["chapters"]).not_to include("Hecks")
  end
end
