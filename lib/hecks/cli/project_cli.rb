require "fileutils"
require_relative "../../hecks"
require_relative "project_cli/launcher_source"

module Hecks
  module CLI
    # The command behind `hecks project_cli` and `hecks project_cli`: writes a
    # command-line launcher beside each domain, named after its bluebook, so
    # `Hecks.bluebook "QualityControl"` in `qa/` becomes `qa/quality_control`.
    #
    # Each launcher is a dozen lines pinning one directory and handing over to
    # `Doors::CliRunner`; the surface itself is projected at the moment it runs,
    # so editing a chapter changes behaviour without regenerating anything.
    #
    # A chapter whose world's `launcher` setting names an `executable` gets its launcher
    # there instead: the Hecks chapter's is the gem's `exe/hecks`.
    module ProjectCli
      # Raised when the project loads no bluebook.
      class Error < RuntimeError; end

      # Build output and other trees under a root that hold no domain a caller means.
      IGNORED = %r{\A(rust|deploy|tmp|coverage)/}

      # One launcher to write: its chapter's name, its label under the root, its file, its text,
      # the snake-cased name and the executable path its chapter's world named (nil when none).
      Target = Struct.new(:name, :label, :file, :text, :snake, :executable)

      extend LauncherSource

      module_function

      # Writes a launcher for each named domain, or for every domain under `root`.
      #
      # `--check` writes nothing and exits 1 when a launcher differs from the one this would
      # write. A domain that cannot boot has none to compare, so it fails too.
      #
      # @param argv [Array<String>] domain paths under `root`, and optionally `--check`
      # @param program [String] how the caller was invoked, named in a launcher's header
      # @param root [String] the directory launchers are written under
      # @param remove_stale_bin [Boolean] delete `root/bin/<name>`, a second front door
      # @return [void]
      # @raise [SystemExit] with status 1 for a launcher out of date, an unreadable domain, a
      #   path outside `root` or an unknown flag
      def call(argv, program:, root:, remove_stale_bin: true)
        flags, paths = argv.partition { |word| word.start_with?("-") }
        refuse_unknown(flags)

        check  = flags.include?("--check")
        wanted = paths.empty? ? domains(root) : paths.map { |path| under_root(root, path) }

        outcomes = wanted.to_h { |path| [path, one(root, path, program, check, remove_stale_bin)] }
        report(outcomes)
      end

      # @api private
      def refuse_unknown(flags)
        unknown = flags - ["--check"]
        abort "hecks project_cli: unknown option #{unknown.first} (the only option is --check)" unless unknown.empty?
      end

      # Says which launchers drifted or could not be made, and exits 1 if any did.
      #
      # @api private
      def report(outcomes)
        drifted = outcomes.select { |_, outcome| outcome == :drifted }.keys
        failed  = outcomes.select { |_, outcome| outcome == :failed }.keys
        return if drifted.empty? && failed.empty?

        warn "launcher out of date for: #{drifted.join(", ")}; run `hecks project_cli #{drifted.join(" ")}`" unless drifted.empty?
        warn "no launcher could be checked or written for: #{failed.join(", ")}" unless failed.empty?
        exit 1
      end

      # A domain path as a path under `root`.
      #
      # @param root [String] the directory launchers are written under
      # @param path [String] the path as typed, relative to `root` or absolute
      # @return [String] the path relative to `root`
      # @raise [SystemExit] when the path is outside `root`
      def under_root(root, path)
        expanded = File.expand_path(path, root)
        inside   = expanded == root || expanded.start_with?("#{root}/")
        abort "hecks project_cli: #{path.inspect} is outside #{root}" unless inside

        relative = expanded.delete_prefix(root).delete_prefix("/")
        relative.empty? ? "." : relative
      end

      # @api private
      # @return [Symbol] `:current` when the launcher is (or was made) as generated, `:drifted`
      #   when `check` found it out of date, `:failed` when the domain could not be read or its
      #   launcher could not be made
      def one(root, path, program, check, remove_stale_bin)
        runtime = Hecks.boot(File.join(root, path), install_doors: false)
        name    = runtime.registry.bluebooks.keys.first or raise Error, "it loads no bluebook"
        setting = Doors::LauncherOptions.settings(runtime, name) || {}
        settle(launcher_target(name, path, setting, root, program), path, root, check, remove_stale_bin)
      rescue StandardError, LoadError => e
        refuse(path, "cannot boot — #{e.message.lines.first.to_s.strip}")
      end

      # Checks the launcher against its file, or writes it.
      #
      # @api private
      # @return [Symbol] as `one` answers
      def settle(target, path, root, check, remove_stale_bin)
        return skip(path, "#{target.label} is a directory") if File.directory?(target.file)
        return :drifted if check && !(File.file?(target.file) && File.read(target.file) == target.text)

        write_launcher(target, root, remove_stale_bin) unless check
        puts "  #{target.label}  ->  #{target.name}"
        :current
      end

      # Works out where one launcher goes and what it says.
      #
      # @api private
      # @return [Target]
      def launcher_target(name, path, setting, root, program)
        snake      = Naming.snake(name)
        executable = setting[:executable]
        label      = executable || "#{path}/#{snake}"
        text       = launcher(path, name, program, executable: executable, legacy: setting[:legacy],
                                                   memory_commands: setting[:memory_commands], opted: !setting.empty?)
        Target.new(name, label, File.join(root, label), text, snake, executable)
      end

      # Writes the launcher, makes it executable, and removes the second front door in `bin/`.
      #
      # @api private
      def write_launcher(target, root, remove_stale_bin)
        File.write(target.file, target.text)
        FileUtils.chmod("+x", target.file)
        FileUtils.rm_f(File.join(root, "bin", target.snake)) if remove_stale_bin && !target.executable
      end

      # @api private
      # @return [Symbol] `:current`: a directory where the launcher would go has nothing to check
      def skip(path, reason)
        warn "  #{path}: #{reason}; no launcher written"
        :current
      end

      # @api private
      def refuse(path, reason)
        warn "  #{path}: #{reason}"
        :failed
      end

      def domains(root)
        folder = Adapters::Folder.new
        Dir.glob(File.join(root, "**/*.hecksagon"))
           .map { |path| folder.domain_root(File.dirname(path)) }
           .compact
           .map { |path| path.delete_prefix("#{root}/") }
           .grep_v(IGNORED)
           .uniq.sort
      end
    end
  end
end
