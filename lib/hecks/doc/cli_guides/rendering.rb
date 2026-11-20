module Hecks
  module Doc
    module CliGuides
      # The Markdown of a CLI guide's generated sections: a module's commands and queries under a
      # heading per aggregate, and the index of the guides with each module's vision.
      module Rendering
        module_function

        # @param layout [Layout] the command line's modules
        # @param module_name [String] the module, such as `Deliver`
        # @return [String] its commands and queries, a heading per aggregate
        def module_section(layout, module_name)
          layout.verbs(module_name).map { |group| group_text(group) }.join("\n")
        end

        # @param layout [Layout] the command line's modules
        # @param words [Array<String>] the module words that have a guide page
        # @return [String] one line per guide, in the order the bluebook declares the modules
        def index(layout, words)
          layout.modules.filter_map do |name, vision|
            word = Naming.snake(name)
            "- [#{word}](#{word}.md): #{vision}" if words.include?(word)
          end.join("\n") << "\n"
        end

        # @param group [Hash] one aggregate's `group`, `description` and `verbs`
        # @return [String] its heading, its first sentence, then one line per verb
        def group_text(group)
          lines = group[:verbs].map { |verb| "- `#{verb[:form]}`: #{verb[:summary]}" }
          ["### #{group[:group]}", "", *([group[:description], ""] unless group[:description].empty?),
           *lines, ""].join("\n")
        end
      end
    end
  end
end
