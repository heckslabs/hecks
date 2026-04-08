  # Hecks::ReadmeGenerator
  #
  # Generates README.md from docs/readme_template.md by replacing {{tags}}
  # with content from the codebase. Supports hand-written prose in docs/content/,
  # usage examples in docs/usage/, and auto-generated tables from code inspection.
  #
  # Supported tags:
  # - {{content:name}} -- includes docs/content/name.md
  # - {{usage:name}} -- includes docs/usage/name.md (strips headers)
  # - {{features}} -- includes FEATURES.md (strips title)
  # - {{connections}} -- generates extension table grouped by category
  # - {{smalltalk}} -- generates Smalltalk-inspired features section
  # - {{validation_rules}} -- generates validation rules table from source
  # - {{cli_commands}} -- generates CLI commands table from source
  # - {{domain_summary}} -- generates aggregate summary table from Bluebook
  # - {{domain_dsl}} -- includes raw Bluebook in a code block
  # - {{domain_policies}} -- generates policy table from Bluebook
  #
  #   ReadmeGenerator.new(project_root).generate
  #

module Hecks
  class ReadmeGenerator
    # @param root [String] absolute path to the project root directory
    def initialize(root)
      @root = root
    end

    # Generate README.md by processing the template file. Reads
    # docs/readme_template.md, replaces all {{tag}} and {{tag:arg}}
    # placeholders with generated content, and writes the result to
    # README.md in the project root.
    #
    # @return [String] the generated README content
    def generate
      template_path = File.join(@root, "hecks_docs/readme_template.md")
      template_path = File.join(@root, "docs/readme_template.md") unless File.exist?(template_path)
      template = File.read(template_path)
      output = template.gsub(/\{\{(\w+)(?::(\w+))?\}\}/) { dispatch($1, $2) }
      File.write(File.join(@root, "README.md"), output)
      output
    end

    private

    # Route a template tag to the appropriate content generator method.
    #
    # @param tag [String] the tag name (e.g., "content", "features")
    # @param arg [String, nil] optional argument after the colon
    # @return [String] the replacement content for this tag
    def dispatch(tag, arg)
      case tag
      when "content"          then read_content("docs/content/#{arg}.md")
      when "usage"            then read_usage("docs/usage/#{arg}.md")
      when "features"         then features
      when "connections"      then connections_section
      when "smalltalk"        then smalltalk
      when "validation_rules" then validation_rules
      when "cli_commands"     then cli_commands
      when "domain_summary"   then domain_summary
      when "domain_dsl"       then domain_dsl
      when "domain_policies"  then domain_policies
      else "<!-- unknown tag: {{#{tag}:#{arg}}} -->"
      end
    end

    # Read a content file from the docs/content/ directory.
    #
    # @param path [String] relative path from project root
    # @return [String] file content stripped of whitespace, or a TODO comment
    def read_content(path)
      full = File.join(@root, path)
      File.exist?(full) ? File.read(full).strip : "<!-- TODO: create #{path} -->"
    end

    # Read a usage doc file, stripping title headers and section headers
    # since the template provides its own section structure.
    #
    # @param path [String] relative path from project root
    # @return [String] usage content with headers removed, or a TODO comment
    def read_usage(path)
      full = File.join(@root, path)
      return "<!-- TODO: create #{path} -->" unless File.exist?(full)

      lines = File.readlines(full)
      # Drop the title (# ...) and any blank lines after it
      lines.shift while lines.first&.match?(/\A(#[^#]|\s*$)/)
      # Strip ## sub-headers — template controls structure
      lines.reject! { |l| l.match?(/\A## /) }
      lines.join.strip
    end

    # Read FEATURES.md and strip the title header.
    #
    # @return [String] features content without the title, or a TODO comment
    def features
      path = File.join(@root, "FEATURES.md")
      return "<!-- TODO: create FEATURES.md -->" unless File.exist?(path)

      content = File.read(path)
      content.sub(/\A# .*\n+/, "").strip
    end

    # Generate a markdown table of validation rules by scanning source files
    # under lib/hecks/validation_rules/. Extracts the class name and first
    # description sentence from each file's doc comment header.
    #
    # @return [String] markdown table with Rule and Description columns
    def validation_rules
      rules = []
      Dir[File.join(@root, "lib/hecks/validation_rules/**/*.rb")].sort.each do |f|
        lines = File.readlines(f)
        next unless lines.first&.start_with?("# Hecks::")

        name = lines.first.sub("# ", "").strip
        next if name.end_with?("::Naming", "::References", "::Structure")
        next if name.include?("BaseRule")

        # Description is the first non-blank comment line after the class name
        desc_line = lines[1..].find { |l| l.match?(/^# \S/) }
        desc = desc_line&.sub(/^#\s*/, "")&.strip || ""
        desc = desc.split(/\.(\s|$)/).first&.strip || desc
        short_name = name.split("::").last
        rules << "| #{short_name} | #{desc} |"
      end
      "| Rule | Description |\n|---|---|\n#{rules.join("\n")}"
    end

    # Generate a markdown table of CLI commands by scanning source files
    # under lib/hecks_cli/commands/. Extracts the command name from the
    # filename and description from the doc comment header.
    #
    # @return [String] markdown table with Command and Description columns
    def cli_commands
      commands = []
      Dir[File.join(@root, "lib/hecks_cli/commands/*.rb")].sort.each do |f|
        lines = File.readlines(f)
        next unless lines.first&.start_with?("# Hecks::")

        desc_line = lines[1..].find { |l| l.match?(/^# \S/) }
        desc = desc_line&.sub(/^#\s*/, "")&.strip || ""
        desc = desc.split(/\.(\s|$)/).first&.strip || desc
        name = File.basename(f, ".rb").gsub("_", " ")
        commands << "| `hecks #{name}` | #{desc} |"
      end
      "| Command | Description |\n|---|---|\n#{commands.join("\n")}"
    end

    def smalltalk
      ""
    end

    # Generate the connections/extensions section grouped by category
    # (persistence, realtime, rails, server, middleware).
    #
    # @return [String] markdown tables of extensions grouped by category
    def connections_section
      categories = {
        persistence: "Persistence",
        realtime: "Real-Time",
        rails: "Rails",
        server: "Servers",
        middleware: "Middleware"
      }
      grouped = ExtensionDocs.by_category
      sections = categories.map do |key, title|
        exts = grouped[key]
        next unless exts&.any?
        rows = exts.map { |e| "| [#{e[:name]}](docs/extensions/#{e[:gem]}.md) | #{e[:description]} | `#{e[:gemfile]}` |" }
        "### #{title}\n\n| Extension | Description | Install |\n|---|---|---|\n#{rows.join("\n")}"
      end.compact
      sections.join("\n\n")
    end

    # Load the domain from Bluebook in the project root. Caches the
    # result across multiple tag evaluations within the same generate call.
    #
    # @return [Hecks::BluebookModel::Domain, nil] the loaded domain, or nil
    #   if Bluebook does not exist
    def load_domain
      @_domain ||= begin
        path = Dir[File.join(@root, "*Bluebook")].first
        return nil unless File.exist?(path)
        Kernel.load(path)
        Hecks.last_domain
      end
    end

    # Generate a markdown table summarizing all aggregates with their
    # commands and value objects.
    #
    # @return [String] markdown table, or a TODO comment if no domain found
    def domain_summary
      domain = load_domain
      return "<!-- no Bluebook found -->" unless domain

      rows = domain.aggregates.map do |agg|
        cmds = agg.commands.map(&:name).join(", ")
        vos = agg.value_objects.map(&:name).join(", ")
        "| **#{agg.name}** | #{cmds} | #{vos} |"
      end

      header = "| Aggregate | Commands | Value Objects |\n|---|---|---|"
      "#{header}\n#{rows.join("\n")}"
    end

    # Include the raw Bluebook DSL source in a code block.
    #
    # @return [String] markdown code block, or a TODO comment if no domain found
    def domain_dsl
      path = Dir[File.join(@root, "*Bluebook")].first
      return "<!-- no Bluebook found -->" unless File.exist?(path)

      "```ruby\n#{File.read(path).strip}\n```"
    end

    # Generate a markdown table of domain-level reactive policies.
    #
    # @return [String] markdown table, "*None*", or a TODO comment
    def domain_policies
      domain = load_domain
      return "<!-- no Bluebook found -->" unless domain
      return "*None*" if domain.policies.empty?

      rows = domain.policies.map do |p|
        "| **#{p.name}** | #{p.event_name} | #{p.trigger_command} |"
      end

      header = "| Policy | On Event | Triggers |\n|---|---|---|"
      "#{header}\n#{rows.join("\n")}"
    end
  end
end
