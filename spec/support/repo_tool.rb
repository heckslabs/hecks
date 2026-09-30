# frozen_string_literal: true

require "rbconfig"
require "hecks/tools"
require "hecks/rust_build"
require "hecks/quality_control/cli/child"

# The repository's own tools as a child process, for a spec that needs a real process (a
# separate boot, its own exit status) without a launcher script to start.
#
# @example
#   Open3.capture3(*RepoTool.argv("project_deploy"), domain_dir, "--out=#{out}")
module RepoTool
  # The checkout the specs run from.
  ROOT = File.expand_path("../..", __dir__)

  # The load path a child runs with.
  LIB = File.join(ROOT, "lib")

  module_function

  # The command that starts a tool, before its own arguments.
  #
  # @param name [String] the tool, by the name of the script it replaced: a `Hecks::Tools` tool, a
  #   `Hecks::RustBuild` tool or a `Hecks::QualityControlCli::Child` command
  # @param root [String] the checkout a QA command runs against
  # @return [Array<String>] the program and its leading arguments
  # @raise [KeyError] when no tool has that name
  def argv(name, root: ROOT)
    if Hecks::Tools.tool?(name)
      [RbConfig.ruby, "-I", LIB, "-e", %(require "hecks/tools"; Hecks::Tools.script(#{name.inspect}, ARGV)), "--"]
    elsif Hecks::RustBuild::TOOLS.key?(name)
      [RbConfig.ruby, "-I", LIB, "-e", %(require "hecks/rust_build"; exit Hecks::RustBuild.run(#{name.inspect}, ARGV)), "--"]
    else
      Hecks::QualityControlCli::Child.argv(root, name)
    end
  end
end
