require_relative "../../naming"
require_relative "templates"

module Hecks
  module CLI
    module ProjectCli
      # The source of one launcher, built from `Templates`. `ProjectCli` extends it.
      module LauncherSource
        include Templates

        # What a chapter name, a domain path and a launcher command may be made of.
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

        # What a Memory command does when refused: say why, from the record's `refusal`.
        MEMORY_REFUSAL = <<~'LAUNCHER_REFUSAL'.gsub(/^/, "  ").freeze
          if MEMORY_COMMANDS.include?(ARGV.first.to_s.chomp("!"))
            why = begin
              require "json"
              JSON.parse(text).dig("state", "refusal", "value")
            rescue JSON::ParserError
              nil
            end
            warn(why ? why.sub(/\A(\w+::)+\w+: /, "") : reason)
          else
            puts text
            warn reason
          end
        LAUNCHER_REFUSAL

        # The generator's name as an executable launcher's header states it, whoever ran it.
        GENERATOR = "hecks project_cli".freeze

        # The launcher's test for a Memory command; a trailing `!` is not part of the name.
        RUNS_ON_MEMORY = 'MEMORY_COMMANDS.include?(ARGV.first.to_s.chomp("!"))'.freeze

        # Where a launcher sits: the path up to the root, how it finds its domain, the program
        # name its header states, the path its usage shows, and the name it runs under.
        Site = Struct.new(:up, :boot, :program, :where, :shown)

        # The source of one launcher; names and paths go in as they are, so each must be plain.
        # An `opted` one also sets UTF-8 and prints a failed `--wait` record on stdout. An
        # executable's program name is its file's basename, and its header names the generator.
        # @param path [String] the domain's directory under the root
        # @param name [String] the chapter's name
        # @param program [String] the generator's invocation, named in the header
        # @param executable [String, nil] the file's path under the root when not beside the domain
        # @param legacy [Array<String>, nil] commands an executable hands to `Hecks::CLI` first
        # @param memory_commands [Array<String>, nil] commands that default to Memory
        # @param opted [Boolean] whether the chapter's world declares a `launcher` setting
        # @return [String] the Ruby source
        # @raise [ArgumentError] if a name, path, executable or legacy command is not plain
        def launcher(path, name, program, executable: nil, legacy: nil, memory_commands: nil, opted: !executable.nil?) # rubocop:disable Metrics/ParameterLists -- the generator's documented signature
          plain!("chapter name", name, NAME)
          plain!("domain path", path, PATH)
          site = executable ? executable_site(path, executable) : plain_site(path, name, program)
          quiet = !Array(memory_commands).empty?

          render(LAUNCHER, name: name, program: site.program, where: site.where, up: site.up,
                           encoding: opted ? ENCODING : "", handoff: handoff_for(executable, legacy, memory_commands),
                           ending: ending_for(opted, executable && quiet),
                           entry: entry(name, site.boot, site.shown, opted, quiet: quiet))
        end

        # @api private
        # @return [String] what an executable launcher does before it boots, or nothing
        def handoff_for(executable, legacy, memory_commands)
          return "" unless executable

          legacy_handoff(Array(legacy)) + memory_default(Array(memory_commands))
        end

        # @api private
        # @return [String] the launcher's closing lines; quiet when a memory command is listed
        def ending_for(opted, quiet)
          ending = opted ? OPTED_ENDING : PLAIN_ENDING
          quiet ? quiet_ending(ending) : ending
        end

        # @api private
        # @return [Site] where an executable launcher sits, named by its path under the root
        def executable_site(path, executable)
          plain!("launcher executable", executable, PATH)
          if executable.split("/").include?("..")
            raise ArgumentError, "launcher executable #{executable.inspect} must stay inside the root"
          end

          up = "../" * File.dirname(executable).split("/").count { |part| part != "." }
          Site.new(up, %(File.expand_path("#{up}#{path}", __dir__)), GENERATOR, executable, File.basename(executable))
        end

        # @api private
        # @return [Site] where a launcher sits beside its domain, named after its chapter
        def plain_site(path, name, program)
          where = "#{path}/#{Naming.snake(name)}"
          Site.new("../" * path.count("/").succ, "__dir__", program, where, where)
        end

        # @api private
        # @return [String] the launcher's middle: for an opted-in launcher, usage answered from the
        #   projection and a boot only for a line that runs a command; for any other, the boot and
        #   dispatch every launcher has always had, byte for byte
        def entry(name, boot, shown, opted, quiet: false)
          opted ? described_entry(name, boot, shown, quiet: quiet) : plain_entry(name, boot, shown)
        end

        # @api private
        # @return [String] the opted-in launcher's middle
        def described_entry(name, boot, shown, quiet: false)
          started = "Hecks.boot_described(described, install_driving: false)"
          started = "Hecks::Adapters::Driving::LauncherOptions.quietly(hold: #{RUNS_ON_MEMORY}) { #{started} }" if quiet
          render(DESCRIBED_ENTRY, boot: boot, shown: shown, name: name, started: started).chomp
        end

        # @api private
        # @return [String] the middle every launcher had before opted-in ones answered usage alone
        def plain_entry(name, boot, shown)
          render(PLAIN_ENTRY, boot: boot, shown: shown, name: name).chomp
        end

        # @api private
        def plain!(what, value, pattern)
          return if value.to_s.match?(pattern)

          raise ArgumentError, "#{what} #{value.to_s.inspect} is not a plain word or path"
        end

        # @api private
        # @param ending [String] the launcher's closing lines
        # @return [String] the same lines, except that a memory command prints no settled record,
        #   only the reason it was refused: a person is at it, so the record is noise
        def quiet_ending(ending)
          ending.sub("  puts text\n  warn reason\n", MEMORY_REFUSAL)
                .sub("status.zero? ? puts(text)",
                     "exit 0 if status.zero? && #{RUNS_ON_MEMORY}\nstatus.zero? ? puts(text)")
        end

        # @api private
        # @return [String] the lines that default the listed commands to Memory, or nothing
        def memory_default(commands)
          return "" if commands.empty?

          commands.each { |command| plain!("memory command", command, VERB) }
          render(MEMORY_DEFAULT, commands: commands.join(" "))
        end

        # @api private
        # @return [String] the lines that hand the legacy commands to `Hecks::CLI`, or nothing
        def legacy_handoff(legacy)
          return "" if legacy.empty?

          legacy.each { |command| plain!("legacy command", command, VERB) }
          render(LEGACY_HANDOFF, commands: legacy.join(" "))
        end
      end
    end
  end
end
