# frozen_string_literal: true

require "stringio"
require "hecks/tools"

# Runs the deploy recipe generator (`hecks deploy project`) in this process, the way the
# `hecks` launcher would, so a spec needs no launcher script and no subprocess.
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
    code = capture(out, err) { Hecks::Tools.fetch("project_deploy").main([domain_dir, *flags], root: root) }
    [out.string, err.string, Result.new(code)]
  end

  # Runs the block with stdout and stderr redirected; returns the exit code it ended with.
  def capture(out, err)
    $stdout = out
    $stderr = err
    yield
    0
  rescue SystemExit => e
    err.puts(e.message) unless e.message == "exit" || e.success?
    e.status
  ensure
    $stdout = STDOUT
    $stderr = STDERR
  end
end
