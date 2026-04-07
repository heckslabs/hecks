# Hecks::Workshop::Tour
#
# Guided walkthrough of the sketch -> play -> build loop. Runs 15 steps
# that demonstrate domain modeling from scratch: creating aggregates,
# adding attributes, defining lifecycles, entering play mode, executing
# commands, and building the domain gem.
#
# Each step displays a title, explanation, and the code being run, then
# executes the action against a fresh workshop. Pauses for Enter between
# steps when stdin is a TTY (skips pauses in CI).
#
#   Tour.new(runner).start
#
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Workshop::TourStepsParagraph,
  base_dir: File.expand_path("tour", __dir__)
)

module Hecks
  class Workshop
    class Tour
      Step = Struct.new(:title, :explanation, :code, :action, keyword_init: true)

      include SketchSteps
      include PlaySteps

      attr_reader :steps

      def initialize(runner)
        @runner = runner
        @steps = build_steps
      end

      def start
        puts ""
        puts "=== Hecks Workshop Tour ==="
        puts "Walk through the sketch -> play -> build loop."
        puts ""

        @steps.each_with_index do |step, i|
          print_step(i + 1, step)
          wait_for_enter
          execute_step(step)
          puts ""
        end

        puts "=== Tour complete! ==="
        puts ""
        puts "You just sketched a domain, played with it live, and built a gem."
        puts "Run `hecks console` to start your own workshop."
        puts ""
        nil
      end

      private

      def print_step(number, step)
        puts "--- Step #{number}/#{@steps.size}: #{step.title} ---"
        puts step.explanation
        puts ""
        puts "  >> #{step.code}"
        puts ""
      end

      def wait_for_enter
        return unless $stdin.respond_to?(:tty?) && $stdin.tty?

        print "Press Enter to continue..."
        $stdin.gets
      end

      def execute_step(step)
        step.action.call(@runner)
      end

      def build_steps
        [
          create_aggregate_step,
          add_title_step,
          add_body_step,
          add_lifecycle_step,
          add_transition_step,
          add_create_command_step,
          browse_step,
          validate_step,
          describe_step,
          enter_play_step,
          create_instance_step,
          query_all_step,
          check_events_step,
          return_to_sketch_step,
          build_step
        ]
      end
    end
  end
end
