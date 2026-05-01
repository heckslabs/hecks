# Hecks::TagScanner
#
# @domain Layout
#
# Scans source files for @domain annotations and data-domain HTML attributes.
# Returns a mapping from aggregate/command references to file paths.
#
#   mapping = Hecks::TagScanner.scan("/path/to/app")
#   mapping["Layout.SelectTab"]  # => ["assets/js/keyboard.js"]
#
module Hecks
  module TagScanner
    def self.scan(dir)
      mapping = Hash.new { |h, k| h[k] = [] }
      Dir.glob(File.join(dir, "**/*.{html,js,rb}")).each do |path|
        rel = path.sub("#{dir}/", "")
        extract_tags(path).each { |tag| mapping[tag] << rel }
      end
      mapping
    end

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
