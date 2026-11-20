require_relative "reference"
require_relative "cli_guides"
require_relative "regions"
require "hecks/tools/tools_doc"

module Hecks
  module Doc
    # The Region sources: what each region of a page is held to, wrapping the generators that
    # already write it. A region names its source as `<source>:<target>`:
    #
    # - `readme:<id>` is README's generated region `id`, rendered by `Reference.render_readme`
    # - `tools:<Section>` is a section table of `docs/tools.md`, rendered by `Tools::ToolsDoc`
    # - `reference:<page>` is a DSL reference page, rendered whole by `Reference.pages`
    # - `cli:<section>` is a CLI guide's generated section, rendered by `CliGuides`
    # - `region:<id>` is the page's own marked region `id`, rendered by `Regions`
    # - `doctest:<path>` is a page whose examples are booted, run by the `doctest` callable given
    #
    # Each comparison renders the whole page once and compares one region of it, so a drift names
    # the region that moved. Prose regions name no source and are never checked.
    class Sources
      # The command that rewrites each projected source.
      REMEDY = { "readme"    => "hecks language_run.project_reference!",
                 "reference" => "hecks language_run.project_reference!",
                 "region"    => "hecks language_run.project_reference!",
                 "tools"     => "hecks regeneration_run.project_tools_doc! --confirm",
                 "cli"       => "hecks regeneration_run.project_tools_doc! --confirm" }.freeze

      # @param root [String] the checkout
      # @param doctest [#call, nil] answers true when the page at a path backs its claims; nil
      #   leaves doctested regions to `spec/guides_spec.rb`, which boots each guide
      # @param committed [#call, nil] reads a page as committed, given its checkout-relative path;
      #   nil reads the file under `root`
      # @param layout [CliGuides::Layout, nil] the command line's modules; nil boots one when a
      #   `cli` region is first compared
      def initialize(root, doctest: nil, committed: nil, layout: nil)
        @root = root
        @layout = layout
        @doctest = doctest
        @committed = committed || method(:read_file)
        @rendered = {}
      end

      # @param path [String] the page the region belongs to
      # @param region [Hash{Symbol => String}] its anchor, kind, source and assertion
      # @return [String, nil] why the region differs from its source, or nil when it does
      def drift(path, region)
        source, target = region[:source].split(":", 2)
        return if source.nil?
        return doctest_drift(path, region, target) if source == "doctest"
        return unmarked(path, region, target) if source == "region" && !marked?(path, target)

        committed, fresh = pair(source, target, path)
        return if committed == fresh

        "#{path}##{region[:anchor]}: differs from what #{region[:source]} renders; run #{REMEDY[source]}"
      end

      private

      # @return [Array(String, String)] the region as committed and as its source renders it
      # @raise [ArgumentError] when the source is not one this class knows
      def pair(source, target, path)
        case source
        when "cli" then cli_pair(path, target)
        when "readme" then readme_pair(target)
        when "tools" then tools_pair(target)
        when "reference" then reference_pair(target)
        when "region" then region_pair(path, target)
        else raise ArgumentError, "no Region source named #{source.inspect}"
        end
      end

      # @return [String, nil] why a doctested page's examples fail, or nil when they pass or are
      #   left to `spec/guides_spec.rb`
      def doctest_drift(path, region, target)
        return if @doctest.nil? || @doctest.call(File.join(@root, target))

        "#{path}##{region[:anchor]}: its examples do not show it #{region[:assertion]}"
      end

      # @return [Array(String, String)] README's region `id` as committed and as rendered
      def readme_pair(id)
        text = @committed.call("README.md")
        @rendered[:readme] ||= Reference.render_readme(@root, text)
        marker = /#{Regexp.escape(Reference.region_begin(id))}.*?#{Regexp.escape(Reference::GENERATED_END)}/m
        [text[marker], @rendered[:readme][marker]]
      end

      # @return [Array(String, String)] `docs/tools.md`'s section table as committed and as rendered
      def tools_pair(section)
        text = @committed.call(Tools::ToolsDoc::DOCUMENT)
        @rendered[:tools] ||= Tools::ToolsDoc.projection(text, @root)
        marker = /<!-- generated:begin tools section=#{Regexp.escape(section)} -->.*?<!-- generated:end tools -->/m
        [text[marker], @rendered[:tools][marker]]
      end

      # @return [Array(String, String, nil)] a reference page as committed and as rendered
      def reference_pair(name)
        directory = File.join(@root, "docs/implemented/reference")
        @rendered[:reference] ||= Reference.pages(directory)
        [@committed.call(File.join("docs/implemented/reference", name)), @rendered[:reference][name]]
      end

      # @return [Array(String, String)] a page's marked region `id` as committed and as rendered
      def region_pair(path, id)
        text = @committed.call(path).to_s
        @rendered[path] ||= Regions.render(@root, path, text)
        [text[Regions.marked(id)], @rendered[path][Regions.marked(id)]]
      end

      # @return [Boolean] whether the committed page carries the markers of region `id`
      def marked?(path, id) = @committed.call(path).to_s.match?(Regions.marked(id))

      # @return [String] that the page has no markers for region `id`, and the marker to add
      def unmarked(path, region, id)
        "#{path}##{region[:anchor]}: has no marked region #{id}; add #{Reference.region_begin(id)}"
      end

      # @return [Array(String, String)] a CLI guide's section as committed and as rendered
      def cli_pair(path, section)
        text = @committed.call(path).to_s
        @layout ||= CliGuides::Layout.new(@root)
        fresh = CliGuides.rewrite(text, section, CliGuides.render(@layout, @root, section))
        [CliGuides.section_text(text, section), CliGuides.section_text(fresh, section)]
      end

      # @return [String, nil] the committed file, or nil when it does not exist
      def read_file(path)
        file = File.join(@root, path)
        File.exist?(file) ? File.read(file, encoding: "UTF-8") : nil
      end
    end
  end
end
