# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaGeneratedDomains
      # The command line of `target.check_generated_domains`: flags into an options hash.
      module Arguments
        # Each flag that takes a value: the option it sets and how the value is read.
        VALUE_FLAGS = {
          "--domains" => [:domains, ->(v) { Integer(v) }], "--start" => [:start, ->(v) { Integer(v) }],
          "--forms" => [:forms, ->(v) { v.split(",") }], "--seeds" => [:seeds, ->(v) { Integer(v) }],
          "--steps" => [:steps, ->(v) { Integer(v) }], "--adversarial" => [:adversarial, ->(v) { Float(v) }],
          "--shrink-budget" => [:shrink_budget, ->(v) { Integer(v) }],
          "--domain-shrink-budget" => [:domain_shrink_budget, ->(v) { Integer(v) }],
          "--check" => [:check, :itself.to_proc], "--binary" => [:binary, :itself.to_proc],
          "--match" => [:match, ->(v) { JSON.parse(v) }], "--promote" => [:promote, :itself.to_proc],
          "--name" => [:name, :itself.to_proc], "--blueprint" => [:blueprint, :itself.to_proc]
        }.freeze

        # Each flag that stands alone, and the option it turns on.
        SWITCH_FLAGS = { "--rust" => :rust, "--from-dials" => :from_dials }.freeze

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
          { domains: 3, start: nil, forms: nil, seeds: 5, steps: 25, adversarial: 0.3, rust: false,
            shrink_budget: 200, domain_shrink_budget: 40, check: nil, binary: nil, match: nil,
            promote: nil, name: nil, sources: [] }
        end

        def parse_flag(options, arg, argv)
          if VALUE_FLAGS.key?(arg)
            key, reader = VALUE_FLAGS.fetch(arg)
            options[key] = reader.call(argv.shift)
          elsif SWITCH_FLAGS.key?(arg)
            options[SWITCH_FLAGS.fetch(arg)] = true
          elsif arg == "--source"
            options[:sources] << argv.shift
          else
            abort "#{USAGE}\nunexpected argument: #{arg.inspect}"
          end
        end
      end
    end
  end
end
