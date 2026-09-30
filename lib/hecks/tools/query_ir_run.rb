# frozen_string_literal: true

require_relative "../tools"

module Hecks
  module Tools
    # Structured queries against the language's own IR: construct diffs, duplicate rules, impact.
    # A thin front end over `Hecks::QueryIR`, which `hecks serve_query_ir_mcp` shares; needs no
    # Postgres.
    #
    #   hecks query_ir constructs [Name ...]
    #   hecks query_ir duplicates [--meta] [domain_dir ...]
    #   hecks query_ir impact Name field     (advisory, not a gate)
    module QueryIrRun
      USAGE = <<~USAGE
        Usage:
          hecks query_ir constructs [Name ...]
          hecks query_ir duplicates [--meta] [domain_dir ...]
          hecks query_ir impact Name field
      USAGE

      module_function

      # Prints the answer to one query.
      #
      # @param argv [Array<String>] `constructs`, `duplicates` or `impact`, then its arguments
      # @param root [String] the checkout (unused: the queries read the loaded language)
      # @return [Integer] 0, or 1 when the arguments are refused
      def main(argv, root: Tools::ROOT)
        _ = root
        require "hecks"
        require "hecks/query_ir"
        args = argv.dup
        case args.shift
        when "constructs" then constructs(args)
        when "duplicates" then duplicates(args)
        when "impact"     then impact(args)
        else
          warn USAGE
          1
        end
      end

      # @param args [Array<String>] construct names, none for all
      # @return [Integer] the exit status
      def constructs(args)
        puts Hecks::QueryIR.format_constructs(Hecks::QueryIR.constructs(args))
        0
      rescue ArgumentError => e
        warn e.message
        1
      end

      # @param args [Array<String>] `--meta` and domain directories
      # @return [Integer] the exit status
      def duplicates(args)
        use_meta = args.delete("--meta") || args.empty?
        domains  = args.empty? ? nil : args

        puts Hecks::QueryIR.format_duplicates(Hecks::QueryIR.duplicates(domains: domains, include_meta: use_meta))
        0
      end

      # @param args [Array<String>] a construct's name and a field's
      # @return [Integer] the exit status
      def impact(args)
        name, field = args
        unless name && field
          warn "usage: hecks query_ir impact Name field"
          return 1
        end

        puts Hecks::QueryIR.format_impact_preview(Hecks::QueryIR.impact_preview(name, field))
        0
      rescue ArgumentError => e
        warn e.message
        1
      end
    end
  end
end
