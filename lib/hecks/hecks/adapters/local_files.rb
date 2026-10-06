# frozen_string_literal: true

require "fileutils"
require_relative "console_capture"
require "hecks/cli/project_cli"
require "hecks/cli/domain_stub"

module Hecks
  module Adapters
    # The `Workspace` port's adapter: writes files into the project the operator is standing in.
    #
    # Custodian commands whose whole effect is files on disk ask it, so the journal records that a
    # write was requested and what came of it, and the writing happens here and nowhere else.
    class LocalFiles
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes a command-line launcher beside each domain of the current directory, or beside the
      # named ones, through `Hecks::CLI::ProjectCli`. A launcher is a generated file that only
      # points at its domain, so an existing one is replaced and nothing else is touched.
      #
      # @param held [Hash] the `Door` record: `domains` (comma separated paths under the current
      #   directory; every domain found when absent)
      # @return [Hash{Symbol => Hash}] `output:` one line per launcher written
      # @raise [ConsoleCapture::Failure] when no launcher was written
      def write(**held)
        domains = plain(held[:domains]).to_s.split(",").map(&:strip).reject(&:empty?)
        text = ConsoleCapture.answer do
          CLI::ProjectCli.call(domains, program: "hecks project_cli", root: Dir.pwd, remove_stale_bin: false)
        end
        unless text.include?("->")
          reason = text.strip.empty? ? "no domain found" : text.strip
          raise ConsoleCapture::Failure, "no launcher written: #{reason}"
        end

        { output: { value: text } }
      end

      # Writes the stub files of a new domain (ADR 0087) into the named directory, or into the
      # snake-cased name under the current one, and prints what it wrote and what to type next.
      # Nothing is replaced: every file is checked before the first is written, and a directory
      # that already holds a bluebook is refused.
      #
      # @param held [Hash] the `Door` record: `name`, and optionally `adapter` and `dir`
      # @return [Hash{Symbol => Hash}] `output:` the report that was printed
      # @raise [ConsoleCapture::Failure] when the name or adapter is refused, or a file exists
      def scaffold(**held)
        name   = plain(held[:name])
        files  = stub_files(name, plain(held[:adapter]))
        target = File.expand_path(plain(held[:dir]) || CLI::DomainStub.directory(name), Dir.pwd)
        refuse_existing!(target, files.keys)
        warn "warning: #{target} is inside the hecks clone; keep a service you deploy outside it." if inside_clone?(target)

        files.each do |path, text|
          full = File.join(target, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, text)
        end
        report = scaffold_report(target, files.keys, plain(held[:adapter]))
        puts report
        { output: { value: report } }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      def stub_files(name, adapter)
        CLI::DomainStub.files(name: name, adapter: adapter)
      rescue ArgumentError => e
        raise ConsoleCapture::Failure, e.message
      end

      def refuse_existing!(target, paths)
        taken = paths.map { |path| File.join(target, path) }.select { |full| File.exist?(full) }
        taken |= Dir.glob(File.join(target, "bluebook", "*.bluebook"))
        return if taken.empty?

        raise ConsoleCapture::Failure,
              "nothing written; already there: #{taken.map { |full| shown(full) }.join(", ")}"
      end

      def inside_clone?(target)
        root = File.expand_path("../../../..", __dir__)
        File.directory?(File.join(root, ".git")) && target.start_with?("#{root}/")
      end

      def shown(full) = full.delete_prefix("#{Dir.pwd}/")

      def scaffold_report(target, paths, adapter)
        where = shown(target)
        lines = ["wrote #{paths.length} files in #{where}/:"] + paths.sort.map { |path| "  #{path}" }
        lines << "" << "next:" << "  hecks docs #{where}/bluebook" << "  hecks console subject=#{where}"
        unless %w[Postgres PostgresEra].include?(adapter)
          lines << "" << "a Lambda deployment needs Postgres: run again with --adapter=Postgres."
        end
        lines.join("\n")
      end
    end
  end
end
