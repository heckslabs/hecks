# frozen_string_literal: true

require "stringio"
require "hecks/tools"

# Runs the deploy recipe generator (`hecks deploy project`) in this process, the way the
# `hecks` launcher would, so a spec needs neither a `bin/` script nor a subprocess.
module ProjectDeployRunner
  # What the run finished with; answers like a `Process::Status` for the specs that check it.
  Result = Struct.new(:exit_code) do
    # @return [Boolean] whether the generator finished without aborting
    def success?
      exit_code.zero?
    end
  end

  module_function

  # @param domain_dir [String] the domain directory to generate for
  # @param flags [Array<String>] the flags (`--out=`, `--tenant=`, `--schema=`, `--environment=`)
  # @param root [String] the checkout whose `deploy/` receives the recipe
  # @return [Array(String, String, Result)] stdout, stderr, and the outcome
  def run(domain_dir, *flags, root: Hecks::Tools::ROOT)
    out = StringIO.new
    err = StringIO.new
    code = 0
    begin
      $stdout = out
      $stderr = err
      Hecks::Tools.fetch("project_deploy").main([domain_dir, *flags], root: root)
    rescue SystemExit => e
      err.puts(e.message) unless e.message == "exit" || e.success?
      code = e.status
    ensure
      $stdout = STDOUT
      $stderr = STDERR
    end
    [out.string, err.string, Result.new(code)]
  end
end
