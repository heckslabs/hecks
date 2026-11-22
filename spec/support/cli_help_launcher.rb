# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

# The launcher's help as a person sees it, read once per line and kept for the run: the help
# snapshot and the description check read the same output, so a run boots each line once.
module CliHelpLauncher
  # The launcher in this checkout.
  EXE = File.expand_path("../../exe/hecks", __dir__)

  # The lines whose help the snapshot pins, by golden name.
  SNAPSHOTS = {
    "hecks" => [],
    "hecks-help" => ["--help"],
    "module-build" => ["build"], "module-check" => ["check"], "module-delegate" => ["delegate"],
    "module-deliver" => ["deliver"], "module-evolve" => ["evolve"], "module-find" => ["find"],
    "module-migrate" => ["migrate"], "module-operate" => ["operate"], "module-release" => ["release"],
    "module-serve" => ["serve"], "module-start" => ["start"], "module-test" => ["test"]
  }.freeze

  # An environment that does not move the output: no usage record, one locale, no database.
  FIXED_ENV = { "HECKS_USAGE" => "off", "LC_ALL" => "C.UTF-8", "HECKS_ENVIRONMENT" => nil,
                "PGHOST" => "127.0.0.1", "PGPORT" => "1", "PGPASSWORD" => nil }.freeze

  module_function

  # What the launcher prints for a line, booted once per line in a run.
  #
  # @param argv [Array<String>] the line's words
  # @return [String] its standard output
  def output(argv)
    @outputs ||= {}
    @outputs[argv] ||= launch(argv)
  end

  # One boot of the launcher with a fresh cache directory.
  def launch(argv)
    Dir.mktmpdir do |cache|
      out, _err, _status = Open3.capture3(FIXED_ENV.merge("HECKS_CACHE_DIR" => cache), RbConfig.ruby, EXE, *argv)
      out
    end
  end
end
