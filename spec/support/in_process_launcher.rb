require "stringio"

# Runs `exe/hecks` in this process instead of starting a Ruby for it.
#
# The launcher file itself is loaded, with ARGV, ENV, the working directory and the standard streams
# set as a child's would be, so a spec sees the same output, error text and exit status as from
# `Open3.capture3(env, RbConfig.ruby, "exe/hecks", ...)`, without paying for a new interpreter and a
# cold load of the library on every call. Specs that are about the process itself (its executable
# bit, what a fresh interpreter does) keep spawning one.
module InProcessLauncher
  EXE = File.expand_path("../../exe/hecks", __dir__)

  # What `exe/hecks` defines at the top level of the interpreter that runs it.
  CONSTANTS = %i[LEGACY MEMORY_COMMANDS].freeze

  # The part of a `Process::Status` the specs read.
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  module_function

  # @param env [Hash{String => String, nil}] variables to set for the run; nil removes one
  # @param argv [Array<String>] the launcher's arguments
  # @param stdin_data [String] what the launcher reads from standard input
  # @param chdir [String] the working directory for the run
  # @return [Array(String, String, Status)] standard output, standard error and the exit status
  def capture3(env, *argv, stdin_data: "", chdir: Dir.pwd)
    streams = { stdin: StringIO.new(stdin_data), stdout: StringIO.new, stderr: StringIO.new }
    status = isolated(env, argv, chdir, streams) { run_launcher }
    [streams[:stdout].string, streams[:stderr].string, Status.new(status)]
  end

  # Holds the process state a launcher run touches, and puts it back afterwards.
  def isolated(env, argv, chdir, streams, &)
    saved = { env: ENV.to_h, argv: ARGV.dup, program: $PROGRAM_NAME, load_path: $LOAD_PATH.dup,
              streams: [$stdin, $stdout, $stderr] }
    env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    ARGV.replace(argv)
    $stdin = streams[:stdin]
    $stdout = streams[:stdout]
    $stderr = streams[:stderr]
    Dir.chdir(chdir, &)
  ensure
    restore(saved)
  end

  def restore(saved)
    $stdin, $stdout, $stderr = saved[:streams]
    $PROGRAM_NAME = saved[:program]
    $LOAD_PATH.replace(saved[:load_path])
    ARGV.replace(saved[:argv])
    ENV.replace(saved[:env])
  end

  # Loads the launcher and answers the status a process running it would exit with.
  def run_launcher
    forget_constants
    $PROGRAM_NAME = EXE
    load EXE
    0
  rescue SystemExit => e
    e.status
  rescue StandardError, ScriptError => e
    warn "#{e.class}: #{e.message}"
    1
  end

  # The launcher's own top-level constants, so loading it again redefines them without a warning
  # (`$VERBOSE = nil` would hide that, and every `warn` the launcher makes with it).
  def forget_constants
    CONSTANTS.each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
  end
end
