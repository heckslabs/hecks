# frozen_string_literal: true

module Hecks
  module Adapters
    class BoxState
      # A project's generated `deploy-box.sh`, read as text for the names it assigns. Nothing is
      # run to learn them.
      class RollScript
        NAME = "deploy-box.sh"

        # A path inside installed or vendored code, or git's own directory.
        VENDORED_PATH = %r{/(node_modules|vendor|\.git)/}

        # The fact each upper-case variable of the script supplies.
        VARIABLES = { box_stack: "BOX_STACK", rds_stack: "RDS_STACK", region: "REGION", directory: "DIR" }.freeze

        # @param project [String] the project's directory
        # @param override [String, nil] another script to read in place of the project's own
        def initialize(project, override = nil)
          @project = project
          @override = override
        end

        # @return [Hash{Symbol => String}] `box_stack`, `rds_stack`, `region` and `directory`
        # @raise [Unreadable] when the script is not found or does not assign one of them
        def names
          text = File.read(path)
          found = VARIABLES.transform_values { |variable| text[/^#{variable}=["']?([^"'\s]+)/, 1] }
          missing = found.select { |_, value| value.nil? }.keys
          return found if missing.empty?

          raise Unreadable, "#{path} assigns no #{VARIABLES.values_at(*missing).join(", ")}"
        end

        # @return [String] the override, else the script in the project itself, else the only one
        #   beneath it
        # @raise [Unreadable] when there is none, or several beneath the project
        def path
          return existing(@override) if @override

          root = File.expand_path(@project.to_s)
          beside = File.join(root, NAME)
          return beside if File.file?(beside)

          only(root, Dir.glob(File.join(root, "**", NAME)).grep_v(VENDORED_PATH).sort)
        end

        private

        def existing(path)
          script = File.expand_path(path.to_s)
          File.file?(script) ? script : raise(Unreadable, "no such script: #{script}")
        end

        def only(root, found)
          return found.first if found.one?
          raise Unreadable, "no #{NAME} under #{root}; generate the AwsBox recipe or pass script=<path>" if found.empty?

          raise Unreadable, "#{found.size} #{NAME} files under #{root}; pass script=<path>: #{found.join(", ")}"
        end
      end
    end
  end
end
