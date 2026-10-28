# frozen_string_literal: true

module Hecks
  module RustBuild
    class ProjectRust
      # The corpus's declared domains, which a corpus run hands every `hecks project_rust` it
      # makes. Given them, a run writes `mod.rs` and Cargo's features for exactly these domains and
      # leaves Cargo's `default` on `default`, so what a domain generates does not depend on which
      # domains ran before it. Without them (a workspace of one's own) a run follows the domains on
      # disk and points `default` at the domain it generated.
      #
      #   hecks project_rust examples/pizzas --declared=banking,pizzas --default=pizzas
      class Declared
        # The flag naming the declared domains, comma-separated.
        DOMAINS_FLAG = "--declared="
        # The flag naming the declared feature Cargo's `default` stays on.
        DEFAULT_FLAG = "--default="

        # @return [Array<String>] the declared domains' feature names
        attr_reader :domains
        # @return [String] the one of them Cargo's `default` stays on
        attr_reader :default

        # Takes the declared flags out of a command line.
        #
        # @param argv [Array<String>] the arguments of `hecks project_rust`
        # @return [Array(Declared, Array<String>), Array(nil, Array<String>)] what the flags
        #   declared (nil when there are none) and the arguments left
        # @raise [Failure] when one flag is given without the other, or `default` is not declared
        def self.split(argv)
          flags, rest = argv.partition { |arg| arg.start_with?(DOMAINS_FLAG, DEFAULT_FLAG) }
          return [nil, rest] if flags.empty?

          domains = value(flags, DOMAINS_FLAG)&.split(",")
          default = value(flags, DEFAULT_FLAG)
          unless domains && default && domains.include?(default)
            raise Failure, "hecks project_rust: #{DOMAINS_FLAG}<a,b,...> and #{DEFAULT_FLAG}<one of them> go together"
          end

          [new(domains, default), rest]
        end

        def self.value(flags, flag)
          flags.find { |arg| arg.start_with?(flag) }&.delete_prefix(flag)
        end
        private_class_method :value

        # @param domains [Array<String>] the declared domains' feature names
        # @param default [String] the declared domain Cargo's `default` stays on
        def initialize(domains, default)
          @domains = domains
          @default = default
        end

        # @return [Array<String>] the flags that declare these domains to `hecks project_rust`
        def flags = ["#{DOMAINS_FLAG}#{domains.join(",")}", "#{DEFAULT_FLAG}#{default}"]
      end
    end
  end
end
