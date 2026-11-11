# frozen_string_literal: true

require "fileutils"

module Hecks
  module Tools
    module AgentRoles
      # The role files the rows project into a directory: it writes them, or compares them.
      class Files
        # The fence that opens and closes the frontmatter of a role file.
        FENCE = /^---\n/

        # A frontmatter key at the start of a line.
        KEY = /^([A-Za-z]\w*):/

        # @param dir [String] the directory holding the role files
        # @param rows [Array<Hash>] the `RoleFile` rows
        def initialize(dir, rows)
          @dir = dir
          @rows = rows
        end

        # @return [Hash{String => String}] each file's path to the text it should hold
        def projection = @rows.to_h { |row| [File.join(@dir, "#{row[:role]}.md"), Render.text(row)] }

        # @return [Array<String>] the paths missing or holding other text
        def stale = projection.reject { |path, text| File.exist?(path) && File.read(path) == text }.keys

        # Compares and writes nothing.
        #
        # @return [Integer] 0 when every file is current, otherwise 1
        def check
          return say("#{@rows.size} files, every one current") if stale.empty?

          warn "agent_roles: out of date: #{stale.map { |path| File.basename(path) }.join(", ")} " \
               "(run hecks regeneration_run.project_agent_roles!)"
          1
        end

        # Writes each stale file, but not one that holds frontmatter the row cannot say.
        #
        # @return [Integer] 0, or 1 when a file was refused
        def write
          refused = stale.select { |path| unsayable(path).any? }
          (stale - refused).each { |path| put(path) }
          refused.each { |path| refuse(path) }
          refused.empty? ? 0 : 1
        end

        private

        def put(path)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, projection.fetch(path))
          puts "wrote #{File.basename(path)}"
        end

        def refuse(path)
          warn "agent_roles: refused #{File.basename(path)}: frontmatter #{unsayable(path).join(", ")} is not in its row"
        end

        # @return [Array<String>] frontmatter keys of the file on disk that the row cannot say
        def unsayable(path)
          return [] unless File.exist?(path)

          File.read(path).split(FENCE, 3)[1].to_s.scan(KEY).flatten - Render::KEYS
        end

        def say(text)
          puts("agent_roles: #{text}")
          0
        end
      end
    end
  end
end
