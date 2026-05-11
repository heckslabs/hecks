module Hecks
  module ExtensionDocs

    # Hecks::ExtensionDocs::ReadmeWriter
    #
    # Generates per-extension Markdown README files from the metadata in
    # ExtensionDocs::EXTENSIONS. Each README includes install instructions,
    # a usage example, and details extracted from the source file header.
    #
    #   Hecks::ExtensionDocs::ReadmeWriter.generate(root)
    #
    module ReadmeWriter
      # Generate a Markdown README for each extension that has a source file
      # present under +root/lib/+. Files are written to +root/docs/extensions/+.
      #
      # @param root [String] the project root directory path
      # @return [Array<String>] paths to all generated README files
      def self.generate(root)
        docs_dir = File.join(root, "docs", "extensions")
        Dir.mkdir(docs_dir) unless File.directory?(docs_dir)
        generated = []

        EXTENSIONS.each do |ext|
          source = File.join(root, "lib", "#{ext[:gem]}.rb")
          next unless File.exist?(source)

          header = extract_header(source)
          readme = build_readme(ext, header)
          path = File.join(docs_dir, "#{ext[:gem]}.md")
          File.write(path, readme)
          generated << path
        end

        generated
      end

      # Extract the leading comment block from a Ruby source file.
      #
      # @param path [String] absolute path to the Ruby source file
      # @return [String] the extracted comment text, stripped of "#" prefixes
      def self.extract_header(path)
        lines = File.readlines(path)
        comment_lines = []
        lines.each do |line|
          break unless line.start_with?("#") || line.strip.empty?
          comment_lines << line.sub(/^#\s?/, "").rstrip if line.start_with?("#")
        end
        # Drop the class name line
        comment_lines.shift if comment_lines.first&.match?(/\A\w+\z/)
        comment_lines.join("\n").strip
      end

      # Build a Markdown README string from extension metadata and a header.
      #
      # @param ext [Hash] extension metadata hash from {EXTENSIONS}
      # @param header [String] extracted source file comment header
      # @return [String] the complete Markdown README content
      def self.build_readme(ext, header)
        lines = []
        lines << "# #{ext[:name]}"
        lines << ""
        lines << ext[:description]
        lines << ""
        lines << "## Install"
        lines << ""
        lines << "```ruby"
        lines << "# Gemfile"
        lines << ext[:gemfile]
        lines << "```"
        lines << ""
        lines << "Add the gem and it auto-wires on boot. No configuration needed."
        lines << ""
        lines << "## Usage"
        lines << ""
        lines << "```ruby"
        lines << ext[:example]
        lines << "```"
        lines << ""
        if header.length > 10
          lines << "## Details"
          lines << ""
          lines << header
          lines << ""
        end
        lines.join("\n")
      end

      private_class_method :extract_header, :build_readme
    end
  end
end
