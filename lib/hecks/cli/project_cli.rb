require "fileutils"
require_relative "../../hecks"

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
      # Build output and other trees under a root that hold no domain a caller means.
      IGNORED = %r{\A(rust|deploy|tmp|coverage)/}

      # What a chapter name, a domain path and a launcher verb may be made of.
      NAME = /\A[A-Za-z][A-Za-z0-9_ ]*\z/
      PATH = %r{\A[\w./-]+\z}
      VERB = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      # Set first in an opted-in launcher, before anything reads a file.
      ENCODING = "Encoding.default_external = Encoding::UTF_8\nEncoding.default_internal = Encoding::UTF_8\n\n".freeze

      # How every launcher ends.
      PLAIN_ENDING = "status.zero? ? puts(text) : abort(text)".freeze

      # How an opted-in launcher ends: a failed `--wait` run still prints its settled record.
      OPTED_ENDING = <<~LAUNCHER_TAIL.chomp.freeze
        # A `--wait` run that failed answers its settled record on stdout, so `| jq` reads it
        # either way, and says why on stderr.
        if reason
          puts text
          warn reason
          exit status
        end
        status.zero? ? puts(text) : abort(text)
      LAUNCHER_TAIL

      # The generator's name as an executable launcher's header states it, whoever ran it.
      GENERATOR = "hecks project_cli".freeze

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
        unknown = flags - ["--check"]
        abort "hecks project_cli: unknown option #{unknown.first} (the only option is --check)" unless unknown.empty?

        check  = flags.include?("--check")
        wanted = paths.empty? ? domains(root) : paths.map { |path| under_root(root, path) }

        outcomes = wanted.to_h { |path| [path, one(root, path, program, check, remove_stale_bin)] }
        drifted  = outcomes.select { |_, outcome| outcome == :drifted }.keys
        failed   = outcomes.select { |_, outcome| outcome == :failed }.keys
        return if drifted.empty? && failed.empty?

        warn "launcher out of date for: #{drifted.join(', ')}; run `hecks project_cli #{drifted.join(' ')}`" unless drifted.empty?
        warn "no launcher could be checked or written for: #{failed.join(', ')}" unless failed.empty?
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
        name    = runtime.registry.bluebooks.keys.first or raise "it loads no bluebook"
        setting    = Doors::LauncherOptions.settings(runtime, name) || {}
        snake      = Naming.snake(name)
        executable = setting[:executable]
        label      = executable || "#{path}/#{snake}"
        file       = File.join(root, label)
        text       = launcher(path, name, program, executable: executable, legacy: setting[:legacy],
                          opted: !setting.empty?)
        return skip(path, "#{label} is a directory") if File.directory?(file)

        return :drifted if check && !(File.file?(file) && File.read(file) == text)

        unless check
          File.write(file, text)
          FileUtils.chmod("+x", file)
          FileUtils.rm_f(File.join(root, "bin", snake)) if remove_stale_bin && !executable
        end
        puts "  #{label}  ->  #{name}"
        :current
      rescue StandardError => e
        refuse(path, "cannot boot — #{e.message.lines.first.to_s.strip}")
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

      # The source of one launcher; names and paths go in as they are, so each must be plain.
      # An `opted` one also sets UTF-8 and prints a failed `--wait` record on stdout.
      # @param path [String] the domain's directory under the root
      # @param name [String] the chapter's name
      # @param program [String] the generator's invocation, named in the header
      # @param executable [String, nil] the file's path under the root when it is not beside the
      #   domain; its program name is then that file's basename, and its header names the generator
      # @param legacy [Array<String>, nil] verbs an executable hands to `Hecks::CLI` first
      # @param opted [Boolean] whether the chapter's world declares a `launcher` setting
      # @return [String] the Ruby source
      # @raise [ArgumentError] if a name, path, executable or legacy verb is not plain
      def launcher(path, name, program, executable: nil, legacy: nil, opted: !executable.nil?)
        plain!("chapter name", name, NAME)
        plain!("domain path", path, PATH)
        snake = Naming.snake(name)
        if executable
          plain!("launcher executable", executable, PATH)
          if executable.split("/").include?("..")
            raise ArgumentError, "launcher executable #{executable.inspect} must stay inside the root"
          end

          up      = "../" * File.dirname(executable).split("/").reject { |part| part == "." }.length
          boot    = %(File.expand_path("#{up}#{path}", __dir__))
          program = GENERATOR
          where   = executable
          shown   = File.basename(executable)
        else
          up    = "../" * path.count("/").succ
          boot  = "__dir__"
          where = shown = "#{path}/#{snake}"
        end

        handoff  = legacy_handoff(Array(legacy)) if executable
        encoding = opted ? ENCODING : ""
        ending   = opted ? OPTED_ENDING : PLAIN_ENDING

        <<~RUBY
          #!/usr/bin/env ruby

          # #{name}'s command line — GENERATED by #{program}. Do not edit.
          #
          # A launcher, not a CLI: the verbs, their arguments and their refusals are
          # projected from the bluebook beside it every time this runs, so a change
          # to the chapter shows up here without re-minting anything.
          #
          #   #{where}                  every verb, and every question
          #   #{where} <verb> --help    what it wants, and how it refuses

          #{encoding}$LOAD_PATH.unshift File.expand_path("#{up}lib", __dir__)
          #{handoff}
          require "hecks"

          #{entry(name, boot, shown, opted)}
          #{ending}
        RUBY
      end

      # @api private
      # @return [String] the launcher's middle: usage answered from the projection, then a boot
      #   only for a line that runs a verb
      def entry(name, boot, shown, opted)
        <<~RUBY.chomp
          # Usage is answered from the projected chapter alone: no adapter is bound and no
          # database is opened. Only a line that runs a verb boots the domain.
          domain = #{boot}
          program = "#{shown}"
          described = begin
            Hecks.describe(domain)
          rescue StandardError => e
            abort "cannot open #{name}: \#{e.message.lines.first.strip}"
          end

          text, status#{', reason' if opted} = Hecks::Doors::CliRunner.usage(
            runtime: described, argv: ARGV, program: program
          )
          unless text
            runtime = begin
              Hecks.boot(domain, install_doors: false)
            rescue StandardError => e
              abort "cannot open #{name}: \#{e.message.lines.first.strip}"
            end
            text, status#{', reason' if opted} = Hecks::Doors::CliRunner.call(
              runtime: runtime, argv: ARGV, program: program
            )
          end
        RUBY
      end

      # @api private
      def plain!(what, value, pattern)
        return if value.to_s.match?(pattern)

        raise ArgumentError, "#{what} #{value.to_s.inspect} is not a plain word or path"
      end

      # @api private
      # @return [String] the lines that hand the legacy verbs to `Hecks::CLI`, or nothing
      def legacy_handoff(legacy)
        return "" if legacy.empty?

        legacy.each { |verb| plain!("legacy verb", verb, VERB) }

        <<~RUBY

          # The names the gem has always shipped keep their positional forms.
          LEGACY = %w[#{legacy.join(' ')}].freeze
          if LEGACY.include?(ARGV.first)
            require "hecks/cli"
            exit Hecks::CLI.start(ARGV) unless Hecks::CLI.launcher_form?(ARGV)
          end
        RUBY
      end
    end
  end
end
