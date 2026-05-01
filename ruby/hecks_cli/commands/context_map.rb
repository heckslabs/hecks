# Hecks::CLI -- context_map command
#
# Renders a DDD context map showing bounded context relationships across
# multiple domains. Reads Bluebook files from a domains/ directory or
# a single Bluebook in the current directory.
#
#   hecks context_map                    # text summary to stdout
#   hecks context_map --mermaid          # Mermaid diagram to stdout
#   hecks context_map --browser          # open diagram in browser
#   hecks context_map --output map.md    # write Mermaid to file
#
Hecks::CLI.handle(:context_map) do |inv|
  domains = load_context_map_domains
  next if domains.empty?

  generator = Hecks::ContextMapGenerator.new(domains)

  if options[:browser]
    mermaid_md = "```mermaid\n#{generator.generate}\n```"
    open_context_map_in_browser(mermaid_md)
  elsif options[:output]
    content = "```mermaid\n#{generator.generate}\n```"
    File.write(options[:output], content + "\n")
    say "Wrote #{options[:output]}", :green
  elsif options[:mermaid]
    say "```mermaid"
    say generator.generate
    say "```"
  else
    say generator.generate_text
  end
end

# Load all domain Bluebooks from domains/ directory or current directory.
#
# @return [Array<Hecks::BluebookModel::Structure::Domain>]
def load_context_map_domains
  domains_dir = File.join(Dir.pwd, "domains")
  if File.directory?(domains_dir)
    Dir[File.join(domains_dir, "*.rb")].sort.map { |p| eval(File.read(p), nil, p, 1) }
  else
    bluebook = Dir[File.join(Dir.pwd, "*Bluebook")].first
    if bluebook && File.exist?(bluebook)
      [load_domain_file(bluebook)]
    else
      say "No domains/ directory or Bluebook found", :red
      []
    end
  end
end

# Open a Mermaid markdown string in the browser as self-contained HTML.
#
# @param mermaid_markdown [String] fenced mermaid block
# @return [String] path to temp file
def open_context_map_in_browser(mermaid_markdown)
  blocks = mermaid_markdown.scan(/```mermaid\n(.*?)```/m).flatten
  body = blocks.map { |b| "<pre class=\"mermaid\">#{b.strip}</pre>" }.join("\n")
  html = <<~HTML
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Hecks Context Map</title>
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
  tmp = Tempfile.new(["hecks_context_map", ".html"])
  tmp.write(html)
  tmp.close
  system("open", tmp.path)
  say "Opened #{tmp.path}", :green
  tmp.path
end
