# Hecks::CLI::Argv
#
# Thor replacement — driven by bluebook domains.
# Discovers commands from *Command aggregates, discovers handlers
# by convention from commands/*.rb files, parses ARGV, routes.
#
# Convention: a handler file defines a proc/lambda in a hash keyed
# by command name. Or it calls argv.handle(:name) { |inv| ... }
#
#   argv = Argv.new
#   argv.register_from_bluebook("nursery/hecks/compiler.bluebook")
#   argv.discover_handlers("lib/**/commands")
#   argv.run(ARGV)
#
module Hecks
  class CLI
    class Argv
      Invocation = Struct.new(:command, :args, :options, keyword_init: true)

      def initialize
        @commands = {}
        @groups = Hash.new { |h, k| h[k] = [] }
        @handlers = {}
        @loaded_files = Set.new
      end

      # --- Registry ---

      def register(name, description, group: "Commands", options: [])
        name = name.to_s
        @commands[name] = { description: description, group: group, options: options }
        @groups[group] << name unless @groups[group].include?(name)
      end

      def handle(name, &block)
        @handlers[name.to_s] = block
      end

      def register_from_domain(domain, group: nil)
        g = group || domain.name

        # Meta-commands: aggregates ending in Command (ValidateCommand → validate)
        domain.aggregates.each do |agg|
          next unless agg.name.end_with?("Command") && agg.name != "Command"
          cli_name = snake_case(agg.name.sub(/Command$/, ""))
          desc = agg.description.to_s
          opts = []
          if (cmd = agg.commands.first)
            cmd.attributes.each do |attr|
              opts << { name: attr.name.to_s, type: attr.type.to_s }
            end
          end
          register(cli_name, desc, group: g, options: opts)
        end

        # Domain commands: every command on every aggregate
        # CreatePizza on Pizza → create_pizza, with attrs as options
        domain.aggregates.each do |agg|
          next if agg.name.end_with?("Command")
          agg.commands.each do |cmd|
            cli_name = snake_case(cmd.name)
            desc = cmd.respond_to?(:goal) && cmd.goal ? cmd.goal.to_s : "#{cmd.name} on #{agg.name}"
            opts = cmd.attributes.map { |attr| { name: attr.name.to_s, type: attr.type.to_s } }
            register(cli_name, desc, group: g, options: opts) unless @commands.key?(cli_name)
          end
        end
      end

      def register_from_bluebook(path)
        return unless File.exist?(path)
        Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
          Kernel.load(File.expand_path(path))
        end
        domain = Hecks.last_domain
        register_from_domain(domain)
        install_domain_handlers(domain, path)
      end

      # Wire domain commands to boot + dispatch through the runtime.
      # CreatePizza name=Margherita → boot domain, dispatch "CreatePizza" with {name: "Margherita"}
      def install_domain_handlers(domain, bluebook_path)
        domain.aggregates.each do |agg|
          next if agg.name.end_with?("Command")
          agg.commands.each do |cmd|
            cli_name = snake_case(cmd.name)
            next if @handlers.key?(cli_name)  # don't override explicit handlers
            command_name = cmd.name
            bp = bluebook_path
            handle(cli_name) do |inv|
              # Build attrs from key=value args and --options
              attrs = {}
              inv.args.each do |arg|
                if arg.include?("=")
                  k, v = arg.split("=", 2)
                  attrs[k] = coerce_value(v)
                else
                  attrs[arg] = true
                end
              end
              inv.options.each { |k, v| attrs[k] = coerce_value(v) }

              # Boot and dispatch
              rt = Hecks.boot(File.dirname(File.dirname(bp)))
              rt = rt.is_a?(Array) ? rt.first : rt
              result = rt.dispatch(command_name, attrs)
              puts "\e[32mok\e[0m: #{result.aggregate_type} ##{result.aggregate_id}"
              if result.respond_to?(:event) && result.event
                puts "  event: #{result.event.name}"
              end
            end
          end
        end
      end

      def coerce_value(v)
        return v.to_i if v =~ /\A-?\d+\z/
        return true if v == "true"
        return false if v == "false"
        v
      end

      def register_all_bluebooks(nursery_dir)
        Dir[File.join(nursery_dir, "hecks", "*.bluebook")].sort.each do |path|
          register_from_bluebook(path)
        end
      end

      # --- Handler Discovery ---

      def load_handler_file(path)
        expanded = File.expand_path(path)
        return if @loaded_files.include?(expanded)
        @loaded_files << expanded
        content = File.read(path)
        if content.include?("register_command")
          load_legacy_handler(expanded)
        end
      end

      # --- Parser ---

      def parse(argv)
        argv = argv.dup
        return special(:_help) if argv.empty?

        cmd = argv.shift

        return special(:_help) if cmd == "help" || cmd == "--help"
        return special(:_version) if cmd == "version" || cmd == "--version"

        if cmd == "help" || argv.first == "--help"
          return special(:_command_help, [cmd])
        end

        args = []
        options = {}

        while (token = argv.shift)
          if token.start_with?("--")
            key = token.sub(/^--/, "")
            if argv.first && !argv.first.start_with?("--")
              options[key] = argv.shift
            else
              options[key] = "true"
            end
          else
            args << token
          end
        end

        Invocation.new(command: cmd, args: args, options: options)
      end

      # --- Router ---

      def route(inv)
        case inv.command
        when "_help"
          print_grouped_help
        when "_version"
          puts "hecks #{Hecks::VERSION}"
        when "_command_help"
          print_command_help(inv.args.first)
        else
          unless @commands.key?(inv.command)
            print_error("Unknown command: #{inv.command}")
            return
          end
          handler = @handlers[inv.command]
          if handler
            handler.call(inv)
          else
            print_error("No handler registered for: #{inv.command}\n  (bluebook registered it but no commands/*.rb file provides the logic)")
          end
        end
      end

      # --- Built-in handlers for commands that need Argv internals ---

      def install_builtins!
        # tree: prints the command registry as a grouped tree
        handle("tree") do |inv|
          puts "\e[1mHecks CLI Commands\e[0m\n\n"
          @groups.each do |group_name, cmd_names|
            puts "\e[32m#{group_name}/\e[0m"
            sorted = cmd_names.sort
            sorted.each_with_index do |name, i|
              connector = i == sorted.length - 1 ? "\\-- " : "|-- "
              entry = @commands[name]
              opts = entry[:options].map { |o| "--#{o[:name]}" }
              opt_str = opts.any? ? "  [#{opts.join(", ")}]" : ""
              puts "  #{connector}#{name}#{opt_str}  # #{entry[:description]}"
            end
            puts
          end
        end

        # inspect: show full domain definition
        handle("inspect") do |inv|
          domain = load_domain(inv)
          next unless domain
          agg_filter = inv.options["aggregate"]
          output = Hecks::CLI::DomainInspector.new(domain).generate(aggregate: agg_filter)
          puts output
        end

        # list: show installed domain gems
        handle("list") do |inv|
          specs = ::Gem::Specification.select { |s| s.name.start_with?("hecks_") || s.metadata["hecks_domain"] }
          if specs.empty?
            puts "No Hecks domains installed."
          else
            puts "\e[32mInstalled Hecks domains:\e[0m"
            specs.group_by(&:name).each do |name, versions|
              puts "  #{name} (#{versions.map { |v| "v#{v.version}" }.join(", ")})"
            end
          end
        end

        # smoketest: run specs
        handle("smoketest") do |inv|
          examples_dir = File.join(Dir.pwd, "examples")
          spec_dir = File.join(Dir.pwd, "spec")
          if File.directory?(examples_dir)
            passed = failed = 0
            Dir[File.join(examples_dir, "*/spec")].sort.each do |sd|
              name = File.basename(File.dirname(sd))
              print "#{name}... "
              if system("rspec #{sd} --format progress --no-color > /dev/null 2>&1")
                puts "\e[32mOK\e[0m"; passed += 1
              else
                puts "\e[31mFAIL\e[0m"; failed += 1
              end
            end
            puts "\n#{passed + failed} suites: #{passed} passed, #{failed} failed"
            exit(failed > 0 ? 1 : 0)
          elsif File.directory?(spec_dir)
            exit(system("rspec #{spec_dir} --format documentation") ? 0 : 1)
          else
            $stderr.puts "\e[31mNo spec/ or examples/ directory found\e[0m"
            exit 1
          end
        end
      end

      # --- Run ---

      def run(argv)
        install_builtins!
        route(parse(argv))
      end

      # --- Help ---

      def print_grouped_help
        puts
        max = @commands.keys.map(&:length).max || 20
        @groups.each do |group_name, cmd_names|
          puts "\e[1m#{group_name}:\e[0m"
          cmd_names.sort.each do |name|
            entry = @commands[name]
            puts "  hecks %-#{max}s  # %s" % [name, entry[:description]]
          end
          puts
        end
        puts "Run `hecks help <command>` for details."
      end

      def print_command_help(name)
        entry = @commands[name]
        unless entry
          print_error("Unknown command: #{name}")
          return
        end
        puts "\e[1mhecks #{name}\e[0m — #{entry[:description]}"
        puts
        if entry[:options].any?
          puts "Options:"
          entry[:options].each do |opt|
            puts "  --%-20s %s" % [opt[:name], opt[:type] || "String"]
          end
        else
          puts "  No options."
        end
      end

      def print_error(msg)
        $stderr.puts "\e[31m#{msg}\e[0m"
        $stderr.puts
        $stderr.puts "Run `hecks help` for available commands."
      end

      private

      def special(cmd, args = [])
        Invocation.new(command: cmd.to_s, args: args, options: {})
      end

      # Load a domain from --domain option, first positional arg, or current dir
      def load_domain(inv)
        path = inv.options["domain"] || inv.args.first
        if path && File.exist?(path)
          Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
            Kernel.load(File.expand_path(path))
          end
          return Hecks.last_domain
        end

        # Try current directory
        hecks_dir = File.join(Dir.pwd, "hecks")
        if File.directory?(hecks_dir)
          bluebooks = Dir[File.join(hecks_dir, "*.bluebook")]
          if bluebooks.any?
            Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
              bluebooks.each { |bp| Kernel.load(bp) }
            end
            return Hecks.last_domain
          end
        end

        $stderr.puts "\e[31mNo domain found. Pass a .bluebook file or run from a directory with hecks/\e[0m"
        nil
      end

      def snake_case(s)
        s.gsub(/([A-Z])/) { "_#{$1.downcase}" }.sub(/^_/, "")
      end

      # Load a legacy Thor register_command file and extract its handler.
      # The file calls Hecks::CLI.register_command(:name, desc) { |*args| ... }
      # We intercept that call, wrap the block to provide Thor-like context
      # (options, say, etc.), and register it as an Argv handler.
      def load_legacy_handler(path)
        argv_instance = self
        original = Hecks::CLI.method(:register_command) rescue nil
        Hecks::CLI.define_singleton_method(:register_command) do |name, _desc = nil, **_opts, &block|
          next unless block
          argv_instance.handle(name.to_s) do |inv|
            # Build a Thor-like context so legacy blocks work
            LegacyContext.set_argv_ref(argv_instance)
            ctx = LegacyContext.new(inv, argv_instance)
            ctx.instance_exec(*inv.args, &block)
          end
        end
        begin
          Kernel.load(path)
        rescue => e
          $stderr.puts "  [argv] skip #{File.basename(path)}: #{e.message}" if ENV["HECKS_DEBUG"]
        ensure
          if original
            Hecks::CLI.define_singleton_method(:register_command, original)
          end
        end
      end

      # Minimal Thor-compatible context for legacy handler blocks.
      class LegacyContext
        attr_reader :options

        def initialize(inv, argv_instance = nil)
          @options = inv.options.transform_keys(&:to_sym)
          @args = inv.args
          @argv = argv_instance
        end

        def say(msg, color = nil)
          if color == :red
            $stderr.puts "\e[31m#{msg}\e[0m"
          elsif color == :green
            puts "\e[32m#{msg}\e[0m"
          elsif color == :yellow
            puts "\e[33m#{msg}\e[0m"
          elsif color == :bold
            puts "\e[1m#{msg}\e[0m"
          else
            puts msg
          end
        end

        def ask(question)
          print "#{question} "
          $stdin.gets&.strip
        end

        def yes?(question)
          answer = ask("#{question} (y/n)")
          answer&.downcase&.start_with?("y")
        end

        def shell
          self
        end

        # Thor compat: self.class.command_groups used by tree command
        def self.command_groups
          @@argv_ref&.instance_variable_get(:@groups) || {}
        end

        def self.set_argv_ref(ref)
          @@argv_ref = ref
        end
      end
    end
  end
end
