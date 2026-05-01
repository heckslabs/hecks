# Hecks::Workshop::Tour::PlaySteps
#
# Tour step definitions for the play phase: entering play mode,
# executing commands, querying data, checking events, returning
# to sketch mode, and building the domain gem.
#
#   include PlaySteps
#   enter_play_step  # => Tour::Step
#
module Hecks
  class Workshop
    class Tour
      module PlaySteps
        def enter_play_step
          Step.new(
            title: "Enter play mode",
            explanation: "Play mode compiles the domain and boots a live runtime.\n" \
                         "You can now execute commands and query data.",
            code: "play!",
            action: ->(r) { r.play! }
          )
        end

        def create_instance_step
          Step.new(
            title: "Create a post",
            explanation: "Execute the CreatePost command with real data.",
            code: 'Post.create(title: "Hello", body: "World")',
            action: ->(r) {
              workshop = r.instance_variable_get(:@workshop)
              workshop.execute("CreatePost", title: "Hello", body: "World")
            }
          )
        end

        def query_all_step
          Step.new(
            title: "Query all posts",
            explanation: "Query the in-memory repository for all posts.",
            code: "Post.all",
            action: ->(r) {
              mod = Object.const_get("TourDomain")
              results = mod::Post.all
              results.each { |post| puts "  #{post.inspect}" }
              puts "#{results.size} post(s) found"
            }
          )
        end

        def check_events_step
          Step.new(
            title: "Check the event log",
            explanation: "Every command emits an event. Let's see what happened.",
            code: "events",
            action: ->(r) { r.events }
          )
        end

        def return_to_sketch_step
          Step.new(
            title: "Return to sketch mode",
            explanation: "Switch back to sketch mode to continue editing your domain.",
            code: "sketch!",
            action: ->(r) { r.sketch! }
          )
        end

        def build_step
          Step.new(
            title: "Build the domain gem",
            explanation: "Generate a full Ruby gem from your domain definition.\n" \
                         "The gem includes models, commands, events, and persistence.",
            code: "build",
            action: ->(r) {
              require "tmpdir"
              workshop = r.instance_variable_get(:@workshop)
              tmpdir = Dir.mktmpdir("hecks-tour-")
              output = workshop.build(version: "1.0.0", output_dir: tmpdir)
              puts "Built to: #{output}"
              FileUtils.rm_rf(tmpdir)
            }
          )
        end
      end
    end
  end
end
