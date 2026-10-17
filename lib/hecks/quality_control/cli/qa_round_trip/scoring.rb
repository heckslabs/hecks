# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
require "timeout"
require_relative "comparison"
require_relative "player"
require_relative "structure"

module Hecks
  module QualityControlCli
    class QaRoundTrip
      # Scores a run of a benchmark's battery against its reference answers: a program (an
      # implementation of the spec, or the binary under recovery), or a recovered Hecks domain,
      # which is also compared with the key declaration by declaration.
      class Scoring
        # How long one script may run in a program before it counts as hung.
        SCRIPT_SECONDS = 120

        # @param bench [Bench] the benchmark scored against
        def initialize(bench)
          @bench = bench
          @comparison = Comparison.new
        end

        # Plays every script through a program reading the protocol on stdin.
        #
        # @param command_line [String] the program and its arguments, as a shell would split them
        # @return [Array(Boolean, String)] whether every script agreed, and the report
        def program(command_line)
          argv = Shellwords.split(command_line)
          each_script { |steps| lines(run_program(argv, steps)) }
          [@comparison.agree?, "#{@comparison.report}\n#{@bench.coverage_report}"]
        end

        # Plays every script against a recovered domain, then compares its declarations with the
        # key's.
        # A declaration of the key's that the domain lacks fails the score as a disagreement does,
        # since the battery may never have exercised it.
        #
        # @param domain_path [String] the recovered domain's directory
        # @param verb_map [Hash{String => String}] protocol commands the recovered domain reaches
        #   through another command of its own
        # @return [Array(Boolean, String)] whether every script agreed, and both reports
        def domain(domain_path, verb_map: {})
          each_script { |steps| Player.new(domain_path, verb_map: verb_map).play(steps) }
          structure = Structure.new(chapter_ir(@bench.key_domain), chapter_ir(domain_path))
          agreed = @comparison.agree? && structure.diff[:missing].empty?
          [agreed, "#{@comparison.report}\n#{@bench.coverage_report}\n\n#{structure.report}"]
        end

        private

        def each_script
          @bench.scripts.each do |script|
            steps = JSON.parse(File.read(script))
            @comparison.add(File.basename(script, ".json"), @bench.reference(script), yield(steps))
          end
        end

        def run_program(argv, steps)
          Timeout.timeout(SCRIPT_SECONDS) { Open3.capture2(*argv, stdin_data: JSON.generate(steps)).first }
        rescue Timeout::Error, SystemCallError
          ""
        end

        # A line that is not JSON counts as no line at all, so the step it should have answered
        # disagrees rather than crashing the score.
        def lines(output)
          output.each_line.filter_map do |line|
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end

        def chapter_ir(domain_path)
          runtime = Hecks.boot(domain_path, environment: nil)
          runtime.registry.bluebook(runtime.registry.bluebooks.keys.first).to_h
        end
      end
    end
  end
end
