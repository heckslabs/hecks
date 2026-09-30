require "fileutils"
require_relative "../../hecks"

module Hecks
  module CLI
    # The command behind `bin/project_cli` and `hecks project_cli`: writes a
    # command-line launcher beside each domain, named after its bluebook, so
    # `Hecks.bluebook "QualityControl"` in `qa/` becomes `qa/quality_control`.
    #
    # Each launcher is a dozen lines pinning one directory and handing over to
    # `Facade::CliRunner`; the surface itself is projected at the moment it runs,
    # so editing a chapter changes behaviour without regenerating anything.
    #
    # A chapter whose world's `launcher` setting names an `executable` gets its launcher
    # there instead: the Hecks chapter's is the gem's `exe/hecks`.
    module ProjectCli
      # Build output and other trees under a root that hold no domain a caller means.
      IGNORED = %r{\A(rust|deploy|tmp|coverage)/}

      # The generator's name as an executable launcher's header states it, whoever ran it.
      GENERATOR = "hecks project_cli".freeze

      module_function

      # Writes a launcher for each named domain, or for every domain under `root`.
      #
      # `--check` in `argv` writes nothing and exits 1 when a launcher on disk differs from the
      # one this would write.
      #
      # @param argv [Array<String>] domain paths under `root`, and optionally `--check`
      # @param program [String] how the caller was invoked, named in a launcher's header
      # @param root [String] the directory launchers are written under
      # @param remove_stale_bin [Boolean] delete `root/bin/<name>`, where a launcher for the same
      #   chapter would otherwise linger as a second front door
      # @return [void]
      # @raise [SystemExit] with status 1 when `--check` finds a launcher out of date
      def call(argv, program:, root:, remove_stale_bin: true)
        check  = argv.include?("--check")
        paths  = argv - ["--check"]
        wanted = paths.empty? ? domains(root) : paths.map { |path| path.delete_prefix("#{root}/").chomp("/") }

        drifted = wanted.filter_map { |path| one(root, path, program, check, remove_stale_bin) }
        return if drifted.empty?

        warn "launcher out of date for: #{drifted.join(', ')}; run `hecks project_cli #{drifted.join(' ')}`"
        exit 1
      end

      # @api private
      # @return [String, nil] the domain's path when `check` found its launcher out of date
      def one(root, path, program, check, remove_stale_bin)
        name = bluebook_name(root, path) or return
        snake      = Naming.snake(name)
        setting    = launcher_setting(root, path, name)
        executable = setting[:executable]
        label      = executable || "#{path}/#{snake}"
        file       = File.join(root, label)
        text       = launcher(path, name, program, executable: executable, legacy: setting[:legacy])

        return path if check && !(File.exist?(file) && File.read(file) == text)

        unless check
          File.write(file, text)
          FileUtils.chmod("+x", file)
          FileUtils.rm_f(File.join(root, "bin", snake)) if remove_stale_bin && !executable
        end
        puts "  #{label}  ->  #{name}"
        nil
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

      # Reads the name from `Hecks.bluebook "…"` rather than the directory, so a
      # domain using `formerly_known_as` gets a launcher under its current name.
      def bluebook_name(root, path)
        Hecks.boot(File.join(root, path), install_facade: false).registry.bluebooks.keys.first
      rescue StandardError => e
        warn "  #{path}: cannot boot — #{e.message.lines.first.strip}"
        nil
      end

      # @api private
      # @return [Hash{Symbol => Object}] the chapter's `launcher` world setting, or an empty hash
      def launcher_setting(root, path, name)
        runtime = Hecks.boot(File.join(root, path), install_facade: false)
        Facade::LauncherOptions.settings(runtime, name) || {}
      rescue StandardError
        {}
      end

      # The source of one launcher.
      #
      # @param path [String] the domain's directory under the root
      # @param name [String] the chapter's name
      # @param program [String] the generator's invocation, named in the header
      # @param executable [String, nil] the file's path under the root when it is not beside the
      #   domain. Its program name is then that file's basename and its header names
      #   `hecks project_cli`, so the text does not depend on who ran the generator.
      # @param legacy [Array<String>, nil] verbs an executable hands to `Hecks::CLI` in their
      #   positional form before the launcher's own forms apply
      # @return [String] the Ruby source
      def launcher(path, name, program, executable: nil, legacy: nil)
        snake = Naming.snake(name)
        if executable
          up      = "../" * File.dirname(executable).split("/").length
          boot    = %(File.expand_path("#{up}#{path}", __dir__))
          program = GENERATOR
          where   = executable
          shown   = File.basename(executable)
        else
          up    = "../" * path.count("/").succ
          boot  = "__dir__"
          where = shown = "#{path}/#{snake}"
        end

        handoff = legacy_handoff(Array(legacy)) if executable

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

          $LOAD_PATH.unshift File.expand_path("#{up}lib", __dir__)
          #{handoff}
          require "hecks"

          runtime = begin
            Hecks.boot(#{boot}, install_facade: false)
          rescue StandardError => e
            abort "cannot open #{name}: \#{e.message.lines.first.strip}"
          end

          text, status = Hecks::Facade::CliRunner.call(
            runtime: runtime, argv: ARGV, program: "#{shown}"
          )
          status.zero? ? puts(text) : abort(text)
        RUBY
      end

      # @api private
      # @return [String] the lines that hand the legacy verbs to `Hecks::CLI`, or nothing
      def legacy_handoff(legacy)
        return "" if legacy.empty?

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
