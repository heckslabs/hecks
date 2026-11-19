require "spec_helper"
require "open3"
require "tmpdir"

# The restricted hecks door hands its MCP server the checkout as the storehouse root and working
# directory, never as `HECKS_CHECKOUT`. That variable names a session's checkout for reads, and a
# server whose children inherit it fills `checkout:` into the main checkout's `hecks config`, which
# the worktree write guard reads, so a door started in a linked worktree refused to start.
#
# The example runs the real door over a stub checkout whose `exe/hecks` writes its environment. It
# needs macOS `sandbox-exec`, so it is filtered out elsewhere, and it covers the restricted path
# only: the unrestricted path (`HECKS_DOOR_ALL=1`) starts only while `ALL_ENABLED` exists beside the
# door, which a spec does not create in the checkout.
module HecksDoorStub
  # The door an agent definition names as its MCP server command.
  DOOR = File.expand_path("../.claude/hecks-door/hecks-helper-door", __dir__)

  module_function

  # @return [Array(String, Hash)] a stub checkout's path and the environment its door's server got
  def run
    Dir.mktmpdir do |dir|
      checkout = stub_checkout(File.join(File.realpath(dir), "stub"))
      [checkout, server_environment(checkout)]
    end
  end

  # @param root [String] where the stub checkout goes
  # @return [String] the root, holding an empty Gemfile and an `exe/hecks` that writes `server.env`
  def stub_checkout(root)
    FileUtils.mkdir_p(File.join(root, "exe"))
    File.write(File.join(root, "Gemfile"), "source \"https://rubygems.org\"\n")
    launcher = File.join(root, "exe", "hecks")
    File.write(launcher, "#!/bin/sh\nenv > \"$PWD/server.env\"\n")
    File.chmod(0o755, launcher)
    root
  end

  # @param checkout [String] the stub checkout the door is started for
  # @return [Hash{String => String}] the environment the server was started with
  def server_environment(checkout)
    env = { "HECKS_CHECKOUT" => checkout, "HECKS_DOOR_ALL" => nil, "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil }
    _out, err, status = Open3.capture3(env, DOOR, stdin_data: "")
    raise "door failed: #{err}" unless status.success?

    File.read(File.join(checkout, "server.env")).lines.to_h { |line| line.chomp.split("=", 2) }
  end
end

RSpec.describe "the restricted hecks door's server environment" do
  sandboxed = File.executable?("/usr/bin/sandbox-exec")

  it "passes the checkout as the storehouse root and leaves HECKS_CHECKOUT out", :aggregate_failures, if: sandboxed do
    checkout, environment = HecksDoorStub.run
    expect(environment).to include("HECKS_STOREHOUSE_ROOT" => checkout)
    expect(environment).not_to have_key("HECKS_CHECKOUT")
  end
end
