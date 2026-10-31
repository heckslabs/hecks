require "fileutils"
require "stringio"
require_relative "../../../../hecks"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The launcher word `tour [dir]` (ADR 0163, plan step 40): writes a sample domain into a new
        # directory, runs one command against it in memory, and says what to type next. It writes
        # only into a directory that does not exist yet.
        module TourWords
          TOUR_NAME = "Tour".freeze
          TOUR_COMMAND = %w[Example.create! name=hello].freeze
          TOUR_DIRECTORY = "hecks-tour".freeze

          # The answer to `tour [dir]`, or nil when the line is not a tour.
          def tour_answer(scope, argv)
            return unless argv.first == "tour"

            target = File.expand_path(argv[1] || TOUR_DIRECTORY, Dir.pwd)
            return { answer: [tour_refusal(target), ExitStatus::REFUSED] } if File.exist?(target)

            write_tour(target)
            { answer: [tour_report(scope, target), ExitStatus::ANSWERED] }
          end

          # The reason a tour refuses a directory that already exists.
          def tour_refusal(target)
            "tour refused: #{shown_tour(target)} already exists; name a new directory: hecks tour <dir>"
          end

          # Writes each stub file of the sample domain under `target`.
          def write_tour(target)
            require_relative "../../../tools/domain_stub"
            Tools::DomainStub.files(name: TOUR_NAME).each do |path, text|
              full = File.join(target, path)
              FileUtils.mkdir_p(File.dirname(full))
              File.write(full, text)
            end
          end

          # The report of a tour: what was written, the command's result, and the next command.
          def tour_report(scope, target)
            shown = shown_tour(target)
            result = capture_run(target)
            ran = "ran: #{scope[:program]} run #{shown} #{TOUR_COMMAND.join(" ")}"
            lines = ["wrote a sample domain in #{shown}/", "", ran, result]
            lines + ["", "next: #{scope[:program]} run #{shown} Example.create! name=yourname"]
          end

          # The command's own answer, from a booted copy of the sample domain. The runner answers
          # without exiting, unlike the launcher's `run`, so the report can carry the text.
          def capture_run(target)
            runtime = Hecks.boot(target, install_driving: false)
            Assembly.bind_ported_runtime(runtime)
            text, _status = CliRunner.call(runtime: runtime, argv: TOUR_COMMAND, program: "hecks run #{target}")
            text.to_s.strip
          end

          # The directory as the user typed it, relative to where they are, when it is inside.
          def shown_tour(target)
            target.delete_prefix("#{Dir.pwd}/")
          end
        end
      end
    end
  end
end
