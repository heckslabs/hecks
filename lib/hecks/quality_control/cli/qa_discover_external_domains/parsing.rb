# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaDiscoverExternalDomains
      # The command line of `target.discover_external_domains`: flags into an options hash.
      module Parsing
        HELP_FLAGS = %w[-h --help].freeze

        private

        # @param argv [Array<String>] consumed as it is read
        # @return [Hash, Symbol] `:projects_dir`, `:max_depth` and `:known_paths`, or `:help` after
        #   the usage line was printed
        def parse(argv)
          options = { projects_dir: DEFAULT_PROJECTS_DIR, max_depth: DEFAULT_MAX_DEPTH, known_paths: nil }
          until argv.empty?
            arg = argv.shift
            if HELP_FLAGS.include?(arg)
              puts USAGE
              return :help
            end
            apply_option(options, arg, argv)
          end
          validate_options(options)
        end

        def apply_option(options, arg, argv)
          case arg
          when "--projects-dir" then options[:projects_dir] = File.expand_path(option_value(arg, argv, "a path"))
          when "--max-depth" then options[:max_depth] = Integer(option_value(arg, argv, "a number"))
          when "--known-path" then (options[:known_paths] ||= []) << File.expand_path(option_value(arg, argv, "a path"))
          else refuse!("unexpected argument #{arg.inspect}")
          end
        end

        def option_value(flag, argv, kind)
          refuse!("#{flag} needs #{kind}") if argv.empty?
          argv.shift
        end

        def validate_options(options)
          refuse!("--max-depth must be >= 0") if options[:max_depth].negative?
          refuse!("#{options[:projects_dir]} is not a directory") unless File.directory?(options[:projects_dir])
          options
        end

        def refuse!(message)
          raise Refused, message
        end
      end
    end
  end
end
