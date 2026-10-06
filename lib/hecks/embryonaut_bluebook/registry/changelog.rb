module Hecks
  module EmbryonautBluebook
    class Registry
      # A package's `CHANGELOG.md`: whether a version has an entry, and what it says. Included in
      # `Registry`.
      module Changelog
        private

        def changelog_entry?(package, version)
          file = File.join(@root, package, "CHANGELOG.md")
          File.file?(file) && File.read(file).match?(/^## #{Regexp.escape(version)}( |$)/)
        end

        # The lines under a version's heading, up to the next heading, without trailing blank lines.
        def changelog_section(package, version)
          on = false
          lines = File.readlines(File.join(@root, package, "CHANGELOG.md"), chomp: true).select do |line|
            on = line.match?(/^## #{Regexp.escape(version)}( |$)/) if line.start_with?("## ")
            on && !line.start_with?("## ")
          end
          lines.join("\n").sub(/\n+\z/, "")
        end
      end
    end
  end
end
