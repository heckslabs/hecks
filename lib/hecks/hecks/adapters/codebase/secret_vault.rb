# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      # The `SecretVault` adapter: runs a program with the secrets a 1Password `op run` env file
      # names, so a key or token never sits in a file, a variable of ours or a command line.
      #
      # It starts `op` through the object it is given, which answers `capture` and `run!` as
      # `Hecks::Release::Runner::Commands` does; a spec hands it a recorder.
      class SecretVault
        # @param commands [#capture, #run!] starts each process
        def initialize(commands:)
          @commands = commands
        end

        # @return [Boolean] whether the 1Password CLI is installed
        def installed?
          @commands.capture("op", "--version").success?
        end

        # Runs a program with the env file's secrets in its environment, its output going to the
        # terminal so a prompt (Touch ID, an approval link) reaches the person.
        #
        # @param env_file [String] the env file `op run` reads, absolute or relative to `chdir`
        # @param argv [Array<String>] the program and its arguments
        # @param chdir [String, nil] the directory to run in
        # @return [true] when the program exits zero
        # @raise [Hecks::Release::Runner::CommandFailed] when it does not
        def run!(env_file, *argv, chdir: nil)
          @commands.run!("op", "run", "--env-file=#{env_file}", "--", *argv, chdir: chdir)
        end
      end
    end
  end
end
