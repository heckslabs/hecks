# frozen_string_literal: true

require "optparse"
require_relative "../projections/deploy/template_diff"

module Hecks
  module CLI
    # The command behind `hecks deploy template_comparison.diff`: compares two
    # CloudFormation templates offline and reports differences by logical id; `--strict` also
    # counts cosmetic differences (comments, key order).
    module DeployTemplateDiff
      module_function

      # Prints the comparison and answers the exit status.
      #
      # @param argv [Array<String>] `<before.yaml> <after.yaml> [--json] [--strict]`
      # @param program [String] the name the usage message calls this command by
      # @return [Integer] 0 when the templates match, 1 when they differ, 2 for bad input
      # @raise [SystemExit] when there are not exactly two templates
      def call(argv, program: "hecks deploy diff")
        options = { json: false, strict: false }
        parser = option_parser(program, options)
        files = parser.parse(argv)
        abort parser.banner unless files.size == 2

        print_report(files, options).different? ? 1 : 0
      rescue ArgumentError => e
        warn e.message
        2
      end

      # Prints the comparison of two templates.
      #
      # @api private
      # @return [Object] the comparison report
      def print_report(files, options)
        diff = Hecks::Projections::Deploy::TemplateDiff
        report = diff.diff_files(files[0], files[1], strict: options[:strict])
        puts(options[:json] ? diff.render_json(report) : diff.render(report))
        report
      end

      # @api private
      def option_parser(program, options)
        OptionParser.new do |opts|
          opts.banner = "usage: #{program} <before.yaml> <after.yaml> [--json] [--strict]"
          opts.on("--json", "write the report as JSON") { options[:json] = true }
          opts.on("--strict", "count cosmetic differences too") { options[:strict] = true }
        end
      end
    end
  end
end
