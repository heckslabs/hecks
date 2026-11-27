require "fileutils"
require "hecks"
require_relative "project_cli/launcher_source"
require "hecks/corpus"

module Hecks
  module Adapters
    class LocalFiles
      # Writes a command-line launcher beside each domain, named after its bluebook, for
      # `Launch.ProjectCli`: `Hecks.bluebook "QualityControl"` in `qa/` becomes
      # `qa/quality_control`.
      #
      # Each launcher is a dozen lines pinning one directory and handing over to
      # `Adapters::Driving::CliRunner`; the surface itself is projected at the moment it runs,
      # so editing a bluebook changes behaviour without regenerating anything.
      #
      # A bluebook whose world's `launcher` setting names an `executable` gets its launcher
      # there instead: the Hecks bluebook's is the gem's `exe/hecks`.
      module ProjectCli
        # Raised when the project loads no bluebook, or a path leaves the root.
        class Error < RuntimeError; end

        # Build output and other trees under a root that hold no domain a caller means.
        IGNORED = %r{\A(rust|deploy|tmp|coverage)/}

        # One launcher to write: its bluebook's name, its label under the root, its file, its
        # text, the snake-cased name and the executable path its bluebook's world named (nil when
        # none).
        Target = Struct.new(:name, :label, :file, :text, :snake, :executable)

        # What one run did: the launchers written or found current (one line each), the domain
        # paths whose launcher drifted or could not be made, and the notes on each.
        Outcome = Struct.new(:written, :drifted, :failed, :notes) do
          # @return [Boolean] whether no launcher drifted and every domain could be read
          def ok? = drifted.empty? && failed.empty?

          # @return [String] the lines written, the notes, then what drifted or failed
          def text = (written + notes + problems).join("\n")

          # @return [Array<String>] a line naming the drifted paths, and one naming the failed
          def problems
            lines = []
            lines << "launcher out of date for: #{drifted.join(", ")}; run `hecks launch.project_cli!`" if drifted.any?
            lines << "no launcher could be checked or written for: #{failed.join(", ")}" if failed.any?
            lines
          end
        end

        extend LauncherSource

        module_function

        # Writes a launcher for each named domain, or for every domain under `root`; with
        # `check`, writes nothing and says which launcher differs from the one this would write.
        # A domain that cannot boot has none to compare, so it fails too.
        #
        # @param paths [Array<String>] domain paths under `root`; every domain when empty
        # @param program [String] how the caller was invoked, named in a launcher's header
        # @param root [String] the directory launchers are written under
        # @param check [Boolean] compare instead of writing
        # @param remove_stale_bin [Boolean] delete `root/bin/<name>`, a second entry point
        # @return [Outcome] what was written, drifted or failed
        # @raise [Error] when a path is outside `root`
        def call(paths, program:, root:, check: false, remove_stale_bin: true)
          wanted = paths.empty? ? domains(root) : paths.map { |path| under_root(root, path) }
          options = { program: program, root: root, check: check, remove_stale_bin: remove_stale_bin }
          Outcome.new([], [], [], []).tap { |outcome| wanted.each { |path| one(path, outcome, options) } }
        end

        # A domain path as a path under `root`.
        #
        # @param root [String] the directory launchers are written under
        # @param path [String] the path as typed, relative to `root` or absolute
        # @return [String] the path relative to `root`
        # @raise [Error] when the path is outside `root`
        def under_root(root, path)
          expanded = File.expand_path(path, root)
          inside   = expanded == root || expanded.start_with?("#{root}/")
          raise Error, "#{path.inspect} is outside #{root}" unless inside

          relative = expanded.delete_prefix(root).delete_prefix("/")
          relative.empty? ? "." : relative
        end

        # Settles one domain's launcher and records how it went in `outcome`.
        #
        # @api private
        # @return [void]
        def one(path, outcome, options)
          settle(target_for(path, options), path, outcome, options)
        rescue StandardError, LoadError => e
          outcome.failed << path
          outcome.notes << "  #{path}: cannot boot — #{Text.first_line(e.message)}"
        end

        # Boots one domain and works out its launcher.
        #
        # @api private
        # @return [Target]
        # @raise [Error] when the domain loads no bluebook
        def target_for(path, options)
          runtime = Hecks.boot(File.join(options[:root], path), install_driving: false)
          name    = runtime.bluebooks.keys.first or raise Error, "it loads no bluebook"
          setting = Adapters::Driving::LauncherOptions.settings(runtime, name) || {}
          launcher_target(name, path, setting, options[:root], options[:program])
        end

        # Checks the launcher against its file, or writes it.
        #
        # @api private
        # @return [void]
        def settle(target, path, outcome, options)
          return outcome.notes << directory_note(path, target) if File.directory?(target.file)

          return outcome.drifted << path if options[:check] && !current?(target)

          write_launcher(target, options) unless options[:check]
          outcome.written << written_line(target)
        end

        # @api private
        # @return [String] the line naming a launcher and its bluebook
        def written_line(target) = "  #{target.label}  ->  #{target.name}"

        # @api private
        # @return [String] why no launcher was written where a directory stands
        def directory_note(path, target) = "  #{path}: #{target.label} is a directory; no launcher written"

        # @api private
        # @return [Boolean] whether the launcher's file holds exactly its text
        def current?(target) = File.file?(target.file) && File.read(target.file) == target.text

        # Works out where one launcher goes and what it says.
        #
        # @api private
        # @return [Target]
        def launcher_target(name, path, setting, root, program)
          snake      = Naming.snake(name)
          executable = setting[:executable]
          label      = executable || "#{path}/#{snake}"
          text       = launcher(path, name, program, executable: executable,
                                                     memory_commands: setting[:memory_commands], opted: !setting.empty?)
          Target.new(name, label, File.join(root, label), text, snake, executable)
        end

        # Writes the launcher, makes it executable, and removes the second entry point in `bin/`.
        #
        # @api private
        def write_launcher(target, options)
          File.write(target.file, target.text)
          FileUtils.chmod("+x", target.file)
          FileUtils.rm_f(File.join(options[:root], "bin", target.snake)) if options[:remove_stale_bin] && !target.executable
        end

        # @param root [String] the directory searched
        # @return [Array<String>] every domain under `root` that holds a hecksagon, relative to it
        def domains(root)
          folder = Adapters::Folder.new
          wiring = Dir.glob(File.join(root, "**/*.hecksagon"))
          roots = wiring.map { |path| folder.domain_root(File.dirname(path)) }
          relative = roots.compact.map { |path| path.delete_prefix("#{root}/") }
          relative.grep_v(IGNORED).uniq.sort
        end
      end
    end
  end
end
