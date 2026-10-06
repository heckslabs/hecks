# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaMineCombinations
      # The command line of `target.mine_combinations`: flags into an options hash.
      module Arguments
        # Each flag that takes a value: the option it sets and how the value is read.
        VALUE_FLAGS = {
          "--candidates" => [:candidates, ->(v) { Integer(v) }], "--seeds" => [:seeds, ->(v) { Integer(v) }],
          "--steps" => [:steps, ->(v) { Integer(v) }], "--adversarial" => [:adversarial, ->(v) { Float(v) }],
          "--repair-rounds" => [:repair_rounds, ->(v) { Integer(v) }], "--agent" => [:agent, :itself.to_proc],
          "--from" => [:from, ->(v) { File.expand_path(v) }]
        }.freeze

        private

        # @param argv [Array<String>] consumed as it is read
        # @return [Hash, Symbol] the options, or `:help` after the usage line was printed
        # @raise [SystemExit] on an unknown flag
        def parse(argv)
          options = default_options
          until argv.empty?
            arg = argv.shift
            if %w[-h --help].include?(arg)
              puts USAGE
              return :help
            end
            parse_flag(options, arg, argv)
          end
          options
        end

        def default_options
          { candidates: 3, rust: false, seeds: 5, steps: 25, adversarial: 0.3, repair_rounds: 1,
            agent: nil, from: nil, brief: false, confine: false, against: [] }
        end

        def parse_flag(options, arg, argv)
          case arg
          when *VALUE_FLAGS.keys
            key, reader = VALUE_FLAGS.fetch(arg)
            options[key] = reader.call(argv.shift)
          when "--rust" then options[:rust] = true
          when "--brief" then options[:brief] = true
          when "--confine" then options[:confine] = true
          when "--against" then options[:against] << File.expand_path(argv.shift)
          else abort "#{USAGE}\nunexpected argument: #{arg.inspect}"
          end
        end
      end
    end
  end
end
