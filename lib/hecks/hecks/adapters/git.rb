# frozen_string_literal: true

require "stringio"
require_relative "shell"
require_relative "console_capture"
require_relative "codebase/publishing"
require "hecks/vendoring/git_environment"
require "hecks/embryonaut_bluebook/vendor_cli"

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
      def capture(*, chdir: nil)
        @shell.capture("git", *, env: Vendoring::GitEnvironment.clean, chdir: chdir)
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

        { report: { value: vendored(held[:package], from, root) } }
      end

      # What the vendor command printed, once it ended well.
      def vendored(package, from, root)
        out = StringIO.new
        err = StringIO.new
        status = EmbryonautBluebook::VendorCli.run(vendor_argv(package, from, root), out: out, err: err, root: root)
        raise ConsoleCapture::Failure, err.string.strip unless status.zero?

        out.string
      end

      # The words the vendor command takes: the package, where from when named, and the project.
      def vendor_argv(package, from, root)
        argv = [plain(package)]
        argv += ["--from", from] if from
        argv + ["--root", root]
      end

      # Checks a project's vendored packages against their `bluebook.lock` files and describes
      # them as the manifest a client image carries, through `Hecks::EmbryonautBluebook::Manifest`.
      #
      # The manifest records the project's own commit and whether its tree has uncommitted changes,
      # read from the repository the project stands in (`unknown` outside one).
      #
      # @param held [Hash] the `Package` query's arguments: `root` (the project; the current
      #   directory when absent)
      # @return [Hash{Symbol => String}] `text:` the manifest as JSON
      # @raise [Runtime::NotFound] naming each package whose files disagree with its lock
      def verify(**held)
        root = File.expand_path(plain(held[:root]) || Dir.pwd)
        raise Runtime::NotFound, "#{root} is not a directory" unless File.directory?(root)

        { text: EmbryonautBluebook::Manifest.new(root, built_from: built_from(root)).to_json_text }
      rescue EmbryonautBluebook::Manifest::Mismatch => e
        raise Runtime::NotFound, e.message
      end

      # Prints the content digest and shape labels of one package, as its `bluebook.lock` records
      # them: `Lock.digest_of` over the package's `bluebook/*.bluebook` files alone, and the labels
      # `Shape.labels` gives the same files. The package is read from `<root>/<package>/bluebook`
      # (a registry), else from `<root>/vendor/embryonaut_bluebooks/<package>/bluebook` (a project
      # that vendors it).
      #
      # @param held [Hash] the `Registry` query's arguments: `package`, and `root` (the current
      #   directory when absent)
      # @return [Hash{Symbol => String}] `text:` a `digest:` line, then a `shape:` line each
      # @raise [Runtime::NotFound] when the package has no `bluebook/` with `*.bluebook` files, or
      #   they do not load
      def digest(**held)
        name = plain(held[:package])
        dir = package_bluebook_dir(File.expand_path(plain(held[:root]) || Dir.pwd), name)
        digest = EmbryonautBluebook::Lock.digest_of(dir) or
          raise Runtime::NotFound, "#{dir} holds no *.bluebook files"
        lines = ["digest: #{digest}", *EmbryonautBluebook::Shape.labels(dir).map { |label| "shape: #{label}" }]
        { text: "#{lines.join("\n")}\n" }
      rescue Vendoring::Error => e
        raise Runtime::NotFound, e.message
      end

      # Judges every package of a bluebook registry against its latest release, through
      # `Hecks::EmbryonautBluebook::Registry#check`.
      #
      # @param held [Hash] the `Registry` query's arguments: `root` (the registry; the current
      #   directory when absent)
      # @return [Hash{Symbol => String}] `text:` the notes and `versions ok`
      # @raise [Runtime::NotFound] naming each package at fault, or when `root` is no repository
      def check(**held)
        report = registry(held).check
        raise Runtime::NotFound, report.to_s unless report.ok?

        { text: report.to_s }
      rescue Vendoring::Error => e
        raise Runtime::NotFound, e.message
      end

      # Tags a package of a bluebook registry at the version its `bluebook.yml` carries, through
      # `Hecks::EmbryonautBluebook::Registry#release`. The tag is made in the local repository and
      # never pushed.
      #
      # @param held [Hash] the `Registry` record: `package`, and `root` (the current directory when
      #   absent)
      # @return [Hash{Symbol => Hash}] `report:` the tag made and the command that publishes it
      # @raise [ConsoleCapture::Failure] when the package breaks a release rule
      def tag(**held)
        { report: { value: registry(held).release(plain(held[:package])).to_s } }
      rescue Vendoring::Error => e
        raise ConsoleCapture::Failure, e.message
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

      # The facts a release of this repository is judged by: branch, tree, versions, changelog and
      # where a tag stands. The rules that judge them are the givens of `PublishingRun.Clear`.
      #
      # @param held [Hash] the `PublishingRun` record: `operation`
      # @return [Hash] each fact, as `Codebase::ReleaseFacts` reads it
      # @raise [ConsoleCapture::Failure] when git or a file cannot be read
      def survey(**held)
        commands = Codebase::Publishing.commands || Hecks::Release::Runner::Commands.new
        Codebase::ReleaseFacts.new(Codebase::Tree.new, commands: commands).gather(plain(held[:operation]))
      end

      private

      def package_bluebook_dir(root, name)
        places = [File.join(name, "bluebook"), File.join("vendor", "embryonaut_bluebooks", name, "bluebook")]
        found = places.map { |place| File.join(root, place) }.find { |dir| File.directory?(dir) }
        found or raise Runtime::NotFound,
                       "#{name} has no bluebook/ directory in #{root} (looked in #{places.join(" and ")})"
      end

      def registry(held)
        EmbryonautBluebook::Registry.new(File.expand_path(plain(held[:root]) || Dir.pwd))
      end

      def built_from(root)
        head = capture("rev-parse", "HEAD", chdir: root)
        status = capture("status", "--porcelain", "--", ".", chdir: root)
        { "commit" => head.ok? ? head.out.strip : "unknown", "dirty" => status.ok? && !status.out.strip.empty? }
      end

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
