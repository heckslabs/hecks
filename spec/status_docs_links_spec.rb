require "spec_helper"

# Every relative markdown link and in-page `#anchor` in the status documents must resolve.
RSpec.describe "status document links" do
  let(:root) { File.expand_path("..", __dir__) }

  # GitHub's heading slug: lowercase, drop punctuation, spaces to hyphens.
  def slug(heading)
    heading.downcase.gsub(/[^\p{Alnum}\s_-]/, "").strip.tr(" ", "-")
  end

  def prose(path)
    File.read(path).gsub(/^```.*?^```/m, "").gsub(/`[^`\n]*`/, "")
  end

  def links(path)
    prose(path).scan(/\]\(([^)\s]+)\)/).flatten.grep_v(%r{\A(?:[a-z]+:|//)})
  end

  def anchors(path)
    File.read(path).gsub(/^```.*?^```/m, "").scan(/^\#{1,6}\s+(.+)$/).flatten.map { |heading| slug(heading) }
  end

  %w[README.md CONTRIBUTING.md docs/1.0-readiness.md].each do |doc|
    it "#{doc} links only to files and headings that exist" do
      path = File.join(root, doc)
      broken = links(path).filter_map do |target|
        file, anchor = target.split("#", 2)
        resolved = file.empty? ? path : File.expand_path(file, File.dirname(path))
        if !File.exist?(resolved)
          "#{target} (no such file)"
        elsif anchor && File.file?(resolved) && resolved.end_with?(".md") && !anchors(resolved).include?(anchor)
          "#{target} (no such heading)"
        end
      end

      expect(broken).to be_empty, "#{doc} has links that do not resolve:\n#{broken.uniq.join("\n")}"
    end
  end
end
