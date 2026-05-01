module Hecks
  class Workshop
    # Hecks::Workshop::VisualizeMode
    #
    # Mixin that adds Mermaid diagram visualization to the Workshop. Wires the
    # existing DomainVisualizer, FlowGenerator, and SliceDiagram generators to
    # produce output in three formats: printed to stdout, written to a Markdown
    # file, or opened as a self-contained HTML page in the browser.
    #
    #   workshop.visualize                        # prints all diagrams
    #   workshop.visualize(:browser)              # opens HTML in browser
    #   workshop.visualize(:file, type: :flows)   # writes flows.md
    #   workshop.visualize(:print, type: :structure)
    #
    module VisualizeMode
      # Dispatch visualization to the requested output format.
      #
      # @param format [Symbol] :print (default), :browser, or :file
      # @param type   [Symbol] :all (default), :structure, :behavior, :flows, :slices
      # @return [void]
      def visualize(format = :print, type: :all)
        case format
        when :print   then visualize_print(type)
        when :browser then visualize_browser(type)
        when :file    then visualize_file(type)
        else
          puts "Unknown format #{format.inspect}. Use :print, :browser, or :file."
        end
      end

      private

      # Print Mermaid markdown to stdout.
      #
      # @param type [Symbol] diagram type selector
      # @return [nil]
      def visualize_print(type)
        puts mermaid_for(to_domain, type)
        nil
      end

      # Write a self-contained HTML page and open it in the default browser.
      #
      # @param type [Symbol] diagram type selector
      # @return [String] path to the written temp file
      def visualize_browser(type)
        content = mermaid_for(to_domain, type)
        html = build_html(content)
        require "tempfile"
        tmp = Tempfile.new(["hecks_visualize", ".html"])
        tmp.write(html)
        tmp.close
        path = tmp.path
        system("open", path)
        puts "Opened #{path}"
        path
      end

      # Write raw Mermaid markdown to a .md file in the current directory.
      #
      # @param type [Symbol] diagram type selector
      # @return [String] path to the written file
      def visualize_file(type)
        content = mermaid_for(to_domain, type)
        filename = "#{type}_diagram.md"
        File.write(filename, content)
        puts "Wrote #{filename}"
        filename
      end

      # Build Mermaid markdown for the given domain and diagram type.
      #
      # @param domain [BluebookModel::Structure::Domain]
      # @param type   [Symbol] :all, :structure, :behavior, :flows, :slices
      # @return [String]
      def mermaid_for(domain, type)
        case type
        when :structure
          "```mermaid\n#{Hecks::DomainVisualizer.new(domain).send(:generate_structure)}\n```"
        when :behavior
          "```mermaid\n#{Hecks::DomainVisualizer.new(domain).send(:generate_behavior)}\n```"
        when :flows
          "```mermaid\n#{Hecks::FlowGenerator.new(domain).generate_mermaid}\n```"
        when :slices
          "```mermaid\n#{Hecks::Features::SliceDiagram.new(domain).generate}\n```"
        else
          Hecks::DomainVisualizer.new(domain).generate
        end
      end

      # Build a self-contained HTML string with Mermaid CDN for browser rendering.
      #
      # @param mermaid_markdown [String] fenced mermaid blocks
      # @return [String] complete HTML document
      def build_html(mermaid_markdown)
        # Strip fences and wrap each block in <pre class="mermaid">
        blocks = mermaid_markdown.scan(/```mermaid\n(.*?)```/m).flatten
        body = blocks.map { |b| "<pre class=\"mermaid\">#{b.strip}</pre>" }.join("\n")
        <<~HTML
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
      end
    end
  end
end
