# Hecks::Generators::ChapterSpecGenerator
#
# Generates exhaustive RSpec specs from Bluebook chapter IR. Produces
# a chapter-level spec plus per-paragraph specs. Each aggregate and
# its commands become executable assertions.
#
#   gen = ChapterSpecGenerator.new(Hecks::Chapters::Runtime)  # loads from runtime.bluebook
#   gen.generate          # => { "runtime_spec.rb" => "...", "runtime/ports_spec.rb" => "..." }
#   gen.chapter_spec      # => just the chapter-level spec string
#   gen.paragraph_specs   # => { "ports" => "...", "mixins" => "..." }
#
module Hecks
  module Generators
    class ChapterSpecGenerator < Hecks::Generator
      # @param chapter_module [Module] a Hecks::Chapters::* module
      def initialize(chapter_module)
        @chapter = chapter_module
        slug = bluebook_snake_name(chapter_module.name.split("::").last)
        @domain = Hecks::Chapters.definition_from_bluebook(slug)
      end

      def generate
        result = {}
        result[chapter_spec_filename] = chapter_spec
        paragraph_specs.each do |para_name, content|
          result["#{chapter_slug}/#{para_name}_spec.rb"] = content
        end
        result
      end

      def chapter_spec
        aggs = inline_aggregates
        build_spec_string(chapter_fqn, chapter_require, aggs, @domain.name, total_count: @domain.aggregates.size)
      end

      def paragraph_specs
        paragraphs.each_with_object({}) do |(para_const, para_mod), hash|
          aggs = paragraph_aggregates(para_mod)
          next if aggs.empty?
          slug = bluebook_snake_name(para_const.to_s)
          hash[slug] = build_spec_string(
            "#{chapter_fqn}::#{para_const}", chapter_require, aggs, nil
          )
        end
      end

      private

      def chapter_name = @chapter.name.split("::").last
      def chapter_slug = bluebook_snake_name(chapter_name)
      def chapter_fqn = @chapter.name
      def chapter_require = "hecks/chapters/#{chapter_slug}"
      def chapter_spec_filename = "#{chapter_slug}_spec.rb"

      def paragraphs
        @chapter.constants.filter_map { |c|
          mod = @chapter.const_get(c)
          [c, mod] if mod.respond_to?(:define)
        }
      end

      def paragraph_aggregate_names
        @paragraph_aggregate_names ||= paragraphs.flat_map { |_, mod|
          b = Hecks::DSL::BluebookBuilder.new("_probe")
          mod.define(b)
          b.build.aggregates.map(&:name)
        }.to_set
      end

      def inline_aggregates
        @domain.aggregates.reject { |a| paragraph_aggregate_names.include?(a.name) }
      end

      def paragraph_aggregates(para_mod)
        b = Hecks::DSL::BluebookBuilder.new("_probe")
        para_mod.define(b)
        names = b.build.aggregates.map(&:name).to_set
        @domain.aggregates.select { |a| names.include?(a.name) }
      end

      def build_spec_string(describe_const, require_path, aggregates, domain_name, total_count: nil)
        lines = []
        lines << spec_header(describe_const)
        lines << "require \"spec_helper\""
        lines << "require \"#{require_path}\""
        lines << ""
        lines << "RSpec.describe #{describe_const} do"
        lines << "  subject(:domain) { Hecks::Chapters.definition_from_bluebook(\"#{chapter_slug}\") }"
        lines << ""
        lines << aggregates_hash(aggregates)
        lines << ""
        lines << domain_name_assertion(domain_name) if domain_name
        lines << total_count_assertion(total_count) if total_count
        lines << aggregate_loop
        lines << "end"
        lines.join("\n") + "\n"
      end

      def spec_header(describe_const)
        [
          "# Generated spec for #{describe_const}",
          "#",
          "# Auto-generated from chapter IR by ChapterSpecGenerator.",
          "# Regenerate — do not hand-edit.",
          "#"
        ].join("\n")
      end

      def aggregates_hash(aggregates)
        lines = ["  aggregates = {"]
        aggregates.each do |agg|
          cmds = agg.commands.map { |c| c.name.inspect }.join(", ")
          lines << "    #{agg.name.inspect} => [#{cmds}],"
        end
        lines << "  }"
        lines.join("\n")
      end

      def domain_name_assertion(name)
        [
          "  it \"returns a Domain named #{name}\" do",
          "    expect(domain.name).to eq(#{name.inspect})",
          "  end",
          ""
        ].join("\n")
      end

      def total_count_assertion(count)
        [
          "  it \"has #{count} total aggregates\" do",
          "    expect(domain.aggregates.size).to eq(#{count})",
          "  end",
          ""
        ].join("\n")
      end

      def aggregate_loop
        [
          "  aggregates.each do |name, commands|",
          "    describe name do",
          "      let(:agg) { domain.aggregates.find { |a| a.name == name } }",
          "",
          '      it "exists with a description" do',
          '        expect(agg).not_to be_nil, "#{name} not found"',
          '        expect(agg.description).not_to be_nil, "#{name} missing description"',
          "      end",
          "",
          '      it "has expected commands" do',
          "        expect(agg.commands.map(&:name)).to match_array(commands)",
          "      end",
          "    end",
          "  end"
        ].join("\n")
      end
    end
  end
end
