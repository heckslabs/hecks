# Hecks::CLI — visualize command
#
# Generates Mermaid diagrams from a Hecks domain and outputs them to
# stdout, a file, or a self-contained HTML page in the browser.
#
#   hecks visualize                      # all diagrams to stdout
#   hecks visualize --type structure     # classDiagram only
#   hecks visualize --type behavior      # flowchart only
#   hecks visualize --type flows         # sequenceDiagram only
#   hecks visualize --type slices        # slice flowchart only
#   hecks visualize --browser            # open HTML in browser
#   hecks visualize --output diagram.md  # write to file
#
Hecks::CLI.register_command(:visualize, "Generate Mermaid diagrams for the domain",
  options: {
    domain:  { type: :string,  desc: "Domain gem name or path" },
    type:    { type: :string,  desc: "Diagram type: structure, behavior, flows, slices (default: all)" },
    browser: { type: :boolean, desc: "Open diagram as HTML in browser" },
    output:  { type: :string,  desc: "Write diagram to file (e.g. diagram.md)" }
  }
) do
  domain = resolve_domain_option
  unless domain
    say "Error: must be run from a directory containing Bluebook", :red
    next
  end

  diagram_type = (options[:type] || "all").to_sym
  content = build_mermaid(domain, diagram_type)

  if options[:browser]
    open_in_browser(content)
  elsif options[:output]
    File.write(options[:output], content)
    say "Wrote #{options[:output]}", :green
  else
    say content
  end
end

# Build Mermaid markdown for the given domain and diagram type.
#
# @param domain [Hecks::DomainModel::Structure::Domain]
# @param type   [Symbol] :all, :structure, :behavior, :flows, :slices
# @return [String]
def build_mermaid(domain, type)
  case type
  when :structure
    "```mermaid\n#{Hecks::DomainVisualizer.new(domain).generate_structure}\n```"
  when :behavior
    "```mermaid\n#{Hecks::DomainVisualizer.new(domain).generate_behavior}\n```"
  when :flows
    "```mermaid\n#{Hecks::FlowGenerator.new(domain).generate_mermaid}\n```"
  when :slices
    "```mermaid\n#{Hecks::Features::SliceDiagram.new(domain).generate}\n```"
  else
    Hecks::DomainVisualizer.new(domain).generate
  end
end

# Write a self-contained HTML file with Mermaid CDN and open it.
#
# @param mermaid_markdown [String] fenced mermaid markdown blocks
# @return [String] path to temp file
def open_in_browser(mermaid_markdown)
  blocks = mermaid_markdown.scan(/```mermaid\n(.*?)```/m).flatten
  body = blocks.map { |b| "<pre class=\"mermaid\">#{b.strip}</pre>" }.join("\n")
  html = <<~HTML
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Hecks Domain Visualization</title>
    </head>
    <body>
      #{body}
      <script type="module">
        import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
        mermaid.initialize({ startOnLoad: true });
      </script>
    </body>
    </html>
  HTML
  require "tempfile"
  tmp = Tempfile.new(["hecks_visualize", ".html"])
  tmp.write(html)
  tmp.close
  path = tmp.path
  system("open", path)
  say "Opened #{path}", :green
  path
end
