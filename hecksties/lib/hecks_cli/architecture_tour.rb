# Hecks::ArchitectureTour
#
# Interactive CLI walkthrough of the Hecks framework internals for
# contributors. Walks through the monorepo layout, Bluebook DSL,
# Hecksagon IR, compiler pipeline, glue layer, generators, workshop,
# AI tools, CLI registration, and spec conventions.
#
# Each step prints a title, explanation, and relevant file paths.
# Pauses for Enter between steps when stdin is a TTY (skips in CI).
#
#   Hecks::ArchitectureTour.new.start
#
require_relative "architecture_tour/steps"

module Hecks
  class ArchitectureTour
    Step = Struct.new(:title, :explanation, :paths, keyword_init: true)

    include Steps

    attr_reader :steps

    def initialize
      @steps = build_steps
    end

    def start
      puts ""
      puts "=== Hecks Architecture Tour ==="
      puts "A contributor's guide to how the framework is built."
      puts ""

      @steps.each_with_index do |step, i|
        print_step(i + 1, step)
        wait_for_enter
      end

      puts "=== Architecture tour complete! ==="
      puts ""
      puts "Explore any component with `hecks console`, or run `hecks tour`"
      puts "for the domain modeler's walkthrough."
      puts ""
      nil
    end

    private

    def print_step(number, step)
      puts "--- Step #{number}/#{@steps.size}: #{step.title} ---"
      puts step.explanation
      puts ""
      step.paths.each { |p| puts "  #{p}" }
      puts ""
    end

    def wait_for_enter
      return unless $stdin.respond_to?(:tty?) && $stdin.tty?

      print "Press Enter to continue..."
      $stdin.gets
    end
  end
end
