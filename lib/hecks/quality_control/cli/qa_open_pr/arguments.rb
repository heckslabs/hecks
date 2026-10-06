# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaOpenPr
      # The command line of `patch.open` and `improvement.open`: flags into an options hash. A wrong
      # command line aborts with the usage line.
      module Arguments
        private

        # @param argv [Array<String>] consumed as it is read
        # @return [Hash, Symbol] the options, or `:help` after the usage line was printed
        # @raise [SystemExit] on a flag without a value, an unknown flag or an inconsistent set
        def parse(argv)
          options = {}
          until argv.empty?
            arg = argv.shift
            if %w[-h --help].include?(arg)
              puts USAGE
              return :help
            end
            read_flag(options, arg, argv)
          end
          validate(options)
        end

        def read_flag(options, arg, argv)
          case arg
          when "--improvement" then options[:improvement] = true
          when "--bug", "--angle", "--title", "--body" then options[arg.delete_prefix("--").to_sym] = flag_value(arg, argv)
          else abort "#{USAGE}\nunexpected argument: #{arg.inspect}"
          end
        end

        def flag_value(flag, argv)
          value = argv.shift
          abort "#{USAGE}\n#{flag} needs a value" if value.nil? || value.empty?
          value
        end

        def validate(options)
          abort "#{USAGE}\n--title is required" unless options[:title]
          validate_citation(options)
          options
        end

        def validate_citation(options)
          abort "#{USAGE}\ngive --bug BUG#n OR --improvement, not both" if options[:bug] && options[:improvement]
          abort "#{USAGE}\ngive --bug BUG#n or --improvement" unless options.key?(:bug) || options.key?(:improvement)
          abort "#{USAGE}\n--angle only means something with --improvement" if options[:angle] && !options[:improvement]
        end
      end
    end
  end
end
