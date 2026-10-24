require "fileutils"

# Makes a bare `rspec` run the whole suite in parallel.
#
# A plain `bundle exec rspec` with no arguments hands over to `parallel_rspec spec`, one worker per
# core, grouped by the file runtimes the previous run left in `tmp/parallel_runtime_rspec.log` (the
# first run has none and groups by file size). Nothing is skipped: it is the same examples, split
# across processes. Any argument (a file, `file:line`, `--tag`, `-e`, `--only-failures`) keeps the
# run serial in this process, as do `CI`, `HECKS_SERIAL=1` and a parallel worker itself. So does any
# program other than `rspec` that loads the specs, such as an MCP server running one example: its
# empty argv is its own, and handing over would replace the server with the whole suite.
module ParallelDefault
  RUNTIME_LOG = "tmp/parallel_runtime_rspec.log".freeze

  module_function

  # @return [Boolean] whether this invocation is a bare `rspec` that should be split across workers
  def applies?(argv: ARGV, env: ENV, program: $PROGRAM_NAME)
    File.basename(program.to_s) == "rspec" && argv.empty? && !env.key?("TEST_ENV_NUMBER") &&
      env["CI"].to_s.empty? && env["HECKS_SERIAL"].to_s.empty?
  end

  # @return [Array<String>] the `parallel_rspec` command for the whole suite
  def command
    grouping = File.exist?(RUNTIME_LOG) ? ["--group-by", "runtime", "--runtime-log", RUNTIME_LOG, "--allowed-missing", "100"] : []
    worker_options = "--format progress --format ParallelTests::RSpec::RuntimeLogger --out #{RUNTIME_LOG}"
    ["bundle", "exec", "parallel_rspec", "spec", *grouping, "-o", worker_options]
  end
end

if ParallelDefault.applies?
  FileUtils.mkdir_p("tmp")
  exec(*ParallelDefault.command)
end
