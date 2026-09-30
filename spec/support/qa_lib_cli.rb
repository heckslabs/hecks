require "open3"

# Runs a `Hecks::QualityControlCli` command as its own process, the way the launcher's
# `hecks quality_control <verb>` reaches it, without going through `bin/`. A separate process keeps
# the environment (`PATH`, `QA_SWEEP_DOMAIN_DIR`, `QA_REPO_DIR`), the exit status and stderr the
# command's own.
module QaLibCli
  ROOT = File.expand_path("../..", __dir__)

  # The library file and class behind each command.
  COMMANDS = {
    "qa_tick"                      => ["qa_tick", "QaTick"],
    "qa_log_bug"                   => ["qa_log_bug", "QaLogBug"],
    "qa_open_pr"                   => ["qa_open_pr", "QaOpenPr"],
    "qa_postgres_migrate"          => ["qa_postgres_migrate", "QaPostgresMigrate"],
    "qa_postgres_role"             => ["qa_postgres_role", "QaPostgresRole"],
    "qa_discover_external_domains" => ["qa_discover_external_domains", "QaDiscoverExternalDomains"],
    "qa_domain_novelty"            => ["qa_domain_novelty", "QaDomainNovelty"],
    "qa_mine_combinations"         => ["qa_mine_combinations", "QaMineCombinations"]
  }.freeze

  # @param command [String] a key of `COMMANDS`
  # @return [Array<String>] the argv that starts the command; append its arguments
  def self.argv(command)
    file, klass = COMMANDS.fetch(command)
    code = <<~RUBY
      $LOAD_PATH.unshift(File.join(#{ROOT.inspect}, "lib"))
      require "hecks/quality_control/cli/#{file}"
      klass = Hecks::QualityControlCli::#{klass}
      takes_root = klass.method(:call).parameters.any? { |_, name| name == :root }
      exit(takes_root ? klass.call(ARGV, root: #{ROOT.inspect}) : klass.call(ARGV))
    RUBY
    ["bundle", "exec", "ruby", "-e", code, "--"]
  end

  # @param command [String] a key of `COMMANDS`
  # @param args [Array<String>] the command's arguments
  # @param env [Hash] extra environment for the process
  # @param chdir [String] the working directory
  # @return [Array(String, String, Process::Status)] stdout, stderr and the exit status
  def self.capture3(command, *, env: {}, chdir: ROOT)
    Open3.capture3(env, *argv(command), *, chdir: chdir)
  end

  # @param command [String] a key of `COMMANDS`
  # @param args [Array<String>] the command's arguments
  # @param env [Hash] extra environment for the process
  # @param chdir [String] the working directory
  # @return [Array(String, Process::Status)] merged stdout and stderr, and the exit status
  def self.capture2e(command, *, env: {}, chdir: ROOT)
    Open3.capture2e(env, *argv(command), *, chdir: chdir)
  end

  # Runs a command in a {QaLedgerFixture::Ledger}'s environment.
  #
  # @param ledger [QaLedgerFixture::Ledger] supplies `QA_SWEEP_DOMAIN_DIR`
  # @param command [String] a key of `COMMANDS`
  # @return [Array(String, String, Process::Status)] stdout, stderr and the exit status
  def self.run(ledger, command, *, env: {}, chdir: ROOT)
    capture3(command, *, env: ledger.env(env), chdir: chdir)
  end
end
