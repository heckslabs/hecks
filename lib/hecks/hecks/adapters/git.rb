# frozen_string_literal: true

require "stringio"
require_relative "shell"
require_relative "console_capture"
require_relative "../../vendoring/git_environment"
require_relative "../../embryonaut_bluebook/vendor_cli"

module Hecks
  module Adapters
    # The `Git` port's adapter: the calls a Custodian command makes to `git`.
    #
    # Every call runs under `Vendoring::GitEnvironment.clean`, so a `GIT_DIR` inherited from a hook
    # or a parent process cannot redirect it to another repository. Subprocesses start through the
    # `Shell` adapter.
    class Git
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @shell = Shell.new
      end

      # Runs `git` in a directory.
      #
      # @param args [Array<String>] the git subcommand and its arguments
      # @param chdir [String, nil] the directory to run in
      # @return [Shell::Result] what git said and how it ended
      def capture(*args, chdir: nil)
        @shell.capture("git", *args, env: Vendoring::GitEnvironment.clean, chdir: chdir)
      end

      # Vendors one package of the bluebook registry into a project, pinned to a release or a
      # commit, through `Hecks::EmbryonautBluebook::VendorCli`.
      #
      # The source is `from`, else `EMBRYONAUT_BLUEBOOKS_SRC`; the project is `root`, else the
      # current directory. `ALLOW_DOWNGRADE=1` lets an older release through, as for the script.
      #
      # @param held [Hash] the `Package` record: `package` (`name` or `name@version-or-commit`),
      #   `from` and `root`
      # @return [Hash{Symbol => Hash}] `report:` what was vendored and whether its storage shape
      #   changed
      # @raise [ConsoleCapture::Failure] when the source is not a git repository, or the vendoring
      #   was refused (no such release, a downgrade, an era-breaking shape change)
      def pin(**held)
        from = plain(held[:from]) || ENV.fetch("EMBRYONAUT_BLUEBOOKS_SRC", nil)
        root = plain(held[:root]) || Dir.pwd
        require_repository!(from)

        argv = [plain(held[:package])]
        argv += ["--from", from] if from
        out = StringIO.new
        err = StringIO.new
        status = EmbryonautBluebook::VendorCli.run(argv + ["--root", root], out: out, err: err, root: root)
        raise ConsoleCapture::Failure, err.string.strip unless status.zero?

        { report: { value: out.string } }
      end

      # Who the repository at a directory commits as: its configured name and email.
      #
      # @param chdir [String, nil] a directory inside the repository; the current one when nil
      # @return [String] `Name <email>`, or whichever half is configured
      # @raise [ConsoleCapture::Failure] when git has neither a name nor an email configured
      def identity(chdir: nil)
        name  = capture("config", "user.name", chdir: chdir).out.strip
        email = capture("config", "user.email", chdir: chdir).out.strip
        who = [name, (email.empty? ? nil : "<#{email}>")].compact.reject(&:empty?).join(" ")
        raise ConsoleCapture::Failure, "git has no user.name or user.email configured to approve as" if who.empty?

        who
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      # A source that is not a repository is worded here; the vendoring's own refusal for it is a
      # bare "no commit" that names neither the directory nor the cause.
      def require_repository!(from)
        return unless from && File.directory?(from)
        return if capture("rev-parse", "--git-dir", chdir: from).ok?

        raise ConsoleCapture::Failure, "#{from} is not a git repository"
      end
    end
  end
end
