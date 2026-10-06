# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaLogBug
      # The command line of `bug.log`: flags into an options hash, and the rules a complete set
      # of options obeys. A wrong command line aborts with the usage line.
      module Arguments
        private

        # @param argv [Array<String>] consumed as it is read
        # @return [Hash, Symbol] the options, or `:help` after the usage line was printed
        # @raise [SystemExit] on a flag without a value or an unknown flag
        def parse(argv)
          options = { tags: [], reproduced: "yes" }
          until argv.empty?
            arg = argv.shift
            if %w[-h --help].include?(arg)
              puts USAGE
              return :help
            end
            read_flag(options, arg, argv)
          end
          options
        end

        def read_flag(options, arg, argv)
          case arg
          when *VALUE_FLAGS then options[arg.delete_prefix("--").to_sym] = flag_value(arg, argv, "a value")
          when "--tag" then options[:tags] << flag_value(arg, argv, "a word")
          else abort "#{USAGE}\nunexpected argument: #{arg.inspect}"
          end
        end

        def flag_value(flag, argv, kind)
          value = argv.shift
          abort "#{USAGE}\n#{flag} needs #{kind}" if value.nil? || value.empty?
          value
        end

        def validate(options)
          %i[sweep title demonstration symptom expectation submitter triage].each do |key|
            abort "#{USAGE}\n--#{key} is required" unless options[key]
          end
          unless DISPOSITIONS.include?(options[:triage])
            abort "#{USAGE}\n--triage must be one of #{DISPOSITIONS.join("|")}, got #{options[:triage].inspect}"
          end
          return if REPRODUCED.include?(options[:reproduced])

          abort "#{USAGE}\n--reproduced must be one of #{REPRODUCED.join("|")}, got #{options[:reproduced].inspect}"
        end
      end
    end
  end
end
