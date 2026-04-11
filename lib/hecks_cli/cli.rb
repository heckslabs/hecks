# Hecks::CLI
#
# Thor-based CLI with grouped commands. Each sub-gem registers
# commands via Hecks::CLI.register_command with a group label.
#
begin
  require "thor"
rescue LoadError
  raise LoadError, "The hecks CLI requires thor. Add gem 'thor' to your Gemfile."
end
require "fileutils"
require "hecks/chapters/cli"
Hecks::Chapters.load_aggregates(
  Hecks::Cli::CliTools,
  base_dir: __dir__
)

module Hecks
  # Hecks::CLI
  #
  # Thor-based CLI entry point with grouped commands registered by each sub-gem.
  #
  class CLI < Thor
    include ConflictHandler
    include DomainHelpers
    include HecksTemplating::NamingHelpers

    def self.exit_on_failure? = true

    @pending_commands = []
    @command_groups = {}

    def self.register_command(name, description, group: nil, options: {}, args: [], &block)
      group ||= infer_group(caller_locations(1, 1).first.path)
      @pending_commands << { name: name, description: description, group: group, options: options, args: args, block: block }
    end

    # Wire a handler block without registering — registration comes from the Bluebook.
    # The block receives an Invocation but is instance_exec'd against a LegacyContext
    # so legacy helpers (options, say, ask, etc.) are available.
    def self.handle(name, &block)
      # Argv intercepts this at load time via load_handle_file.
      # No-op in the Thor path; handlers wired by argv at runtime.
    end

    # Infer group from the file path. Uses CLI_GROUP constant on the
    # registering module if available, otherwise derives from gem name.
    # hecks_workshop → "Workshop", hecks_cli/commands/build.rb → "Cli"
    def self.infer_group(path)
      if path =~ /hecks_(\w+)/
        Hecks::Utils.humanize(Hecks::Utils.sanitize_constant($1))
      else
        "Commands"
      end
    end


    def self.pending_commands = @pending_commands
    def self.command_groups = @command_groups

    def self.install_commands!
      @pending_commands.each do |cmd|
        desc_args = cmd[:args].empty? ? cmd[:name].to_s : "#{cmd[:name]} #{cmd[:args].join(' ')}"
        desc desc_args, cmd[:description]
        cmd[:options].each { |n, opts| method_option n.to_s, **opts }
        define_method(cmd[:name], &cmd[:block])
        (@command_groups[cmd[:group]] ||= []) << cmd
      end
      @pending_commands = []
    end

    # Custom help that groups commands
    desc "help [COMMAND]", "Describe available commands"
    def help(command = nil)
      if command
        self.class.command_help(shell, command)
      else
        print_grouped_help
      end
    end

    private

    def print_grouped_help
      groups = self.class.command_groups
      max_name = groups.values.flatten.map { |c| c[:args].empty? ? c[:name].to_s.length : "#{c[:name]} #{c[:args].join(' ')}".length }.max || 20

      groups.each do |group_name, commands|
        shell.say ""
        shell.say "#{group_name}:", :bold
        commands.sort_by { |c| c[:name] }.each do |cmd|
          name = cmd[:args].empty? ? cmd[:name].to_s : "#{cmd[:name]} #{cmd[:args].join(' ')}"
          shell.say "  hecks %-#{max_name}s  # %s" % [name, cmd[:description]]
        end
      end

      shell.say ""
      shell.say "Subcommands:", :bold
      shell.say "  hecks gem build              # Build all component gems"
      shell.say "  hecks gem install            # Install all component gems"
      shell.say "  hecks docs update            # Update doc headers and markdown"
      shell.say ""
      shell.say "Run `hecks help COMMAND` for details on a specific command."
    end

    # Subcommands
    # Hecks::CLI::Gem
    #
    # Thor subcommand group for gem packaging commands (build, install).
    #
    class Gem < Thor
    end

    # Hecks::CLI::Docs
    #
    # Thor subcommand group for documentation update commands.
    #
    class Docs < Thor
      desc "update", "Update all doc headers and markdown files"
      def update
        script = File.expand_path("../../../bin/update-docs", __FILE__)
        exec(script) if File.exist?(script)
        say "bin/update-docs not found", :red
      end
    end

    desc "docs SUBCOMMAND", "Documentation commands", hide: true
    subcommand "docs", Docs

    desc "gem SUBCOMMAND", "Gem packaging commands", hide: true
    subcommand "gem", Gem

    # Load CLI internals (version_log_formatter, etc.) — must happen after CLI < Thor
    Hecks::Chapters.load_aggregates(
      Hecks::Cli::CliInternals,
      base_dir: File.expand_path("..", __FILE__)
    )

    # Load CLI internals that live outside commands/
    require "hecks_cli/version_log_formatter"

    # Load commands from all hecks modules
    lib_root = File.expand_path("../..", __FILE__)
    Dir[File.join(lib_root, "**/commands/*.rb")].sort.each { |f| require f }
    install_commands!

    map "generate:config"     => :generate_config
    map "generate:sinatra"    => :generate_sinatra
    map "generate:stub"       => :generate_stub
    map "generate:migrations" => :generate_migrations
    map "generate:sql"        => :generate_sql
    map "db:migrate"          => :db_migrate
    map "new"                 => :new_project
  end
end
