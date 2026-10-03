# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      # The marked regions of a template a project owns, where the generated blocks go.
      #
      # A region is a pair of comment lines, `# BEGIN GENERATED site_cdn <name> ...` and
      # `# END GENERATED site_cdn <name>`, at the indentation the block's lines take. Everything
      # outside the pair is the project's; everything inside is replaced on each run.
      module Regions
        module_function

        # @param name [String] a region's name
        # @return [Regexp] the region: its begin line, whatever is inside, its end line
        def pattern(name)
          escaped = Regexp.escape(name)
          /^([ \t]*)# BEGIN GENERATED site_cdn #{escaped}\b[^\n]*\n.*?^\1# END GENERATED site_cdn #{escaped}$/m
        end

        # @param text [String] a template
        # @param name [String] a region's name
        # @return [Boolean] whether the template has the region
        def region?(text, name) = text.match?(pattern(name))

        # @param text [String] a template
        # @param name [String] a region's name
        # @param block [String] the lines that go inside, from the left margin
        # @return [String] the template with the region's markers and block rewritten
        def replace(text, name, block)
          text.sub(pattern(name)) do
            indent = Regexp.last_match(1)
            [
              "#{indent}# BEGIN GENERATED site_cdn #{name} (hecks site site_projection.project_site; edit the Route and Edge rows). Do not hand-edit.",
              block.each_line.map { |line| line.strip.empty? ? line : "#{indent}#{line}" }.join.chomp,
              "#{indent}# END GENERATED site_cdn #{name}"
            ].join("\n")
          end
        end
      end
    end
  end
end
