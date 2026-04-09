# Hecks::Capabilities::ProductExecutor::TagScanner
#
# @domain ProductExecutor
#
# Scans source files for @domain annotations and data-domain HTML attributes,
# building a mapping from aggregate/command references to file paths. Used by
# Uncle Bob to surgically edit the right files.
#
#   mapping = TagScanner.scan("/path/to/appeal")
#   mapping["Layout.SelectTab"]  # => ["assets/js/keyboard.js", "assets/js/actions.js"]
#
module Hecks
  module Capabilities
    module ProductExecutor
      module TagScanner
        # Scan a directory for domain tags and return a mapping.
        #
        # @param dir [String] root directory to scan
        # @return [Hash<String, Array<String>>] tag => [relative file paths]
        def self.scan(dir)
          mapping = Hash.new { |h, k| h[k] = [] }

          Dir.glob(File.join(dir, "**/*.{html,js,rb}")).each do |path|
            rel = path.sub("#{dir}/", "")
            tags = extract_tags(path)
            tags.each { |tag| mapping[tag] << rel }
          end

          mapping
        end

        # List all files that touch a given aggregate.
        #
        # @param dir [String] root directory
        # @param aggregate [String] aggregate name (e.g., "Layout")
        # @return [Array<String>] relative file paths
        def self.files_for_aggregate(dir, aggregate)
          mapping = scan(dir)
          mapping.select { |tag, _| tag.start_with?(aggregate) }.values.flatten.uniq
        end

        # List all files that touch a specific command.
        #
        # @param dir [String] root directory
        # @param aggregate [String] aggregate name
        # @param command [String] command name
        # @return [Array<String>] relative file paths
        def self.files_for_command(dir, aggregate, command)
          mapping = scan(dir)
          key = "#{aggregate}.#{command}"
          mapping[key] || []
        end

        # Extract all domain tags from a single file.
        #
        # @param path [String] absolute file path
        # @return [Array<String>] domain tags found
        def self.extract_tags(path)
          content = File.read(path)
          tags = []
          content.scan(/data-domain="([^"]+)"/) { |m| tags << m[0] }
          content.scan(%r{(?://|#)\s*@domain\s+(.+)$}) do |m|
            m[0].split(",").each { |t| tags << t.strip }
          end
          tags.uniq
        end

        private_class_method :extract_tags
      end
    end
  end
end
