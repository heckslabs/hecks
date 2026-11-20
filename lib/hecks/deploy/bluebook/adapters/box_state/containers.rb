# frozen_string_literal: true

module Hecks
  module Adapters
    class BoxState
      # The containers of a box's Compose project, as the listing run on the box printed them: one
      # line per container, with its service, image, the image's revision label and its status
      # separated by tabs.
      class Containers
        # The label a built image carries its commit in.
        REVISION = "org.opencontainers.image.revision"

        # The shell that lists the containers. It reads the Compose project and each image's label
        # and changes nothing; a box with no project prints nothing.
        #
        # @param directory [String] the project's directory on the box
        # @return [String]
        def self.listing(directory)
          <<~SH.strip
            cd #{directory} 2>/dev/null && [ -f compose.json ] || exit 0
            docker compose -f compose.json ps --format '{{.Service}}\t{{.Image}}\t{{.Status}}' | while IFS='\t' read -r s i t; do
              r=$(docker inspect --format '{{index .Config.Labels "#{REVISION}"}}' "$i" 2>/dev/null || true)
              printf '%s\\t%s\\t%s\\t%s\\n' "$s" "$i" "$r" "$t"
            done
          SH
        end

        # @param printed [String] what the listing printed
        def initialize(printed)
          @rows = printed.lines.map { |line| line.chomp.split("\t", 4) }.select { |row| row.size == 4 }
        end

        # @return [String] one line per container: service, image tag and status
        def running
          @rows.map { |service, image, _, status| "#{service} #{image.split(":").last} #{status}" }.join("\n")
        end

        # @return [String] each distinct revision the running images carry, separated by spaces;
        #   empty when none carries one
        def commit
          revisions.uniq.join(" ")
        end

        # @param service [String] a service of the Compose project
        # @return [String] the image tag that service runs; empty when it is not on the box
        def tag_of(service)
          _, image = @rows.find { |name, *| name == service }
          image ? tag(image) : ""
        end

        private

        def tag(image) = image.split(":").last

        # The revision of each container whose image carries one.
        def revisions
          @rows.map { |row| row[2] }.reject { |revision| revision.empty? || revision == "<no value>" }
        end
      end
    end
  end
end
