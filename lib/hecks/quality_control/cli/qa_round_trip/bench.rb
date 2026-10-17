# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../../../fuzzing/domain_generator"
require_relative "../../../fuzzing/sequence_generator"
require_relative "protocol"
require_relative "player"

module Hecks
  module QualityControlCli
    class QaRoundTrip
      # A benchmark on disk: a domain nobody wrote, what an implementer is given, and the scripts
      # with Hecks's own answers that a program or a recovered domain is scored against.
      #
      #   key/            the generated domain: the answer key, never shown to an analyst
      #   spec.bluebook   the implementer's copy of the key's bluebook
      #   PROTOCOL.md     the input and output an implementation follows
      #   prompts/        the implementer's and the analyst's briefs
      #   battery/        sNNN.json protocol scripts and sNNN.ref, Hecks's answers to each
      class Bench
        # The templates `prepare` copies, from beside this file.
        TEMPLATES = File.join(__dir__, "templates")

        # Where an existing benchmark keeps its parts.
        #
        # @param root [String] the benchmark's directory
        def initialize(root)
          @root = File.expand_path(root)
        end

        # @return [String] the benchmark's directory
        attr_reader :root

        # @return [String] the generated domain's directory, which `Hecks.boot` boots
        def key_domain = Dir[File.join(@root, "key", "*")].find { |path| File.directory?(path) }

        # @return [Array<String>] the battery's scripts, in order
        def scripts = Dir[File.join(@root, "battery", "s*.json")]

        # Reads a script's reference answers.
        #
        # @param script [String] one of `scripts`
        # @return [Array<Hash>] the reference's lines
        def reference(script) = File.readlines(script.sub(/\.json\z/, ".ref")).map { |line| JSON.parse(line) }

        # What the battery exercised: each command it sent, with how many times the reference
        # accepted and refused it. A command never refused has no guard the battery could catch
        # a recovery dropping; one never accepted has no effect it could check.
        #
        # @return [Hash{String => Array(Integer, Integer)}] command => `[accepted, refused]`
        def coverage
          scripts.each_with_object(Hash.new { |hash, command| hash[command] = [0, 0] }) do |script, tally|
            tally_script(tally, script)
          end
        end

        # Names the commands the battery never accepted and never refused.
        #
        # @return [String] one line for each gap, or that there are none
        def coverage_report
          tally = coverage
          never = { "never accepted" => 0, "never refused" => 1 }.filter_map do |label, index|
            commands = tally.select { |_, counts| counts[index].zero? }.keys.sort
            "#{label}: #{commands.join(", ")}" unless commands.empty?
          end
          never.empty? ? "coverage: every command was both accepted and refused" : "coverage gaps — #{never.join("; ")}"
        end

        # Generates the domain and writes the whole benchmark.
        #
        # @param seed [Integer] the domain generator's seed; the battery's seeds follow from it
        # @param forms [Array<String>, nil] the generator's forms, or nil to let the seed pick them
        # @param battery [Hash] `scripts:`, `steps:` and `adversarial:` for the sequence generator
        # @return [Integer] how many scripts the battery holds
        # @raise [ArgumentError] if the domain names an aggregate by several fields, which the
        #   protocol cannot express
        def prepare(seed:, forms:, battery:)
          FileUtils.mkdir_p(@root)
          blueprint = Fuzzing::DomainGenerator.generate(seed: seed, forms: forms)
          Fuzzing::DomainGenerator.write(blueprint, File.join(@root, "key"))
          protocol = Protocol.new(chapter_ir(key_domain))
          refuse_composite!(protocol)
          write_brief
          write_battery(protocol, seed, **battery)
        end

        private

        def refuse_composite!(protocol)
          composite = protocol.composite_aggregates
          return if composite.empty?

          raise ArgumentError, "#{composite.join(", ")} is named by several fields, which the protocol cannot " \
                               "express; choose another seed or other forms"
        end

        def write_brief
          FileUtils.cp(Dir[File.join(key_domain, "bluebook", "*.bluebook")].first, File.join(@root, "spec.bluebook"))
          FileUtils.cp(File.join(TEMPLATES, "PROTOCOL.md"), @root)
          FileUtils.mkdir_p(File.join(@root, "prompts"))
          %w[implementer.md analyst.md].each { |name| FileUtils.cp(File.join(TEMPLATES, name), File.join(@root, "prompts")) }
        end

        def write_battery(protocol, seed, scripts:, steps:, adversarial:)
          FileUtils.mkdir_p(File.join(@root, "battery"))
          scripts.times do |index|
            generated = Fuzzing::SequenceGenerator.generate(key_domain, seed: (seed * 1000) + index, steps: steps,
                                                                        adversarial: adversarial)
            write_script(format("s%03d", index), generated.filter_map { |step| playable(protocol, step) })
          end
          scripts
        end

        def playable(protocol, step) = step.key?("verb") || step.key?("query") ? protocol.step(step) : nil

        def tally_script(tally, script)
          steps = JSON.parse(File.read(script))
          reference(script).select { |line| line.key?("step") }.each do |line|
            command = steps[line["step"]]["command"]
            tally[command][line["ok"] ? 0 : 1] += 1 if command
          end
        end

        def write_script(name, steps)
          path = File.join(@root, "battery", name)
          File.write("#{path}.json", JSON.pretty_generate(steps))
          File.write("#{path}.ref", Player.new(key_domain).play(steps).map { |line| JSON.generate(line) }.join("\n") << "\n")
        end

        def chapter_ir(domain)
          runtime = Hecks.boot(domain, environment: nil)
          runtime.registry.bluebook(runtime.registry.bluebooks.keys.first).to_h
        end
      end
    end
  end
end
