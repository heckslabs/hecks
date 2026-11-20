module Hecks
  module Doc
    module Regions
      # The bluebooks this library declares, one line each: its name, the directories its files
      # sit in, and its declared vision. Read off the `.bluebook` files under `lib/hecks`, the way
      # README's corpus roster reads the examples, so a bluebook added or moved changes the list.
      #
      # @example
      #   Hecks::Doc::Regions::BluebookMap.render(root)
      #   # => "- **Docs** (`lib/hecks/docs/`): A documentation page is made of regions, ..."
      module BluebookMap
        # Where the library's bluebooks live, relative to the checkout.
        LIBRARY = "lib/hecks".freeze

        # A `Hecks.bluebook "Name"` line, capturing the name.
        NAME = /^\s*Hecks\.bluebook\s+"([^"]+)"/

        # A `vision "..."` line, capturing the vision.
        VISION = /^\s*vision\s+"([^"]*)"/

        module_function

        # @param root [String] the checkout
        # @return [String] one list item per bluebook, ordered by its first directory
        def render(root)
          declared(root).sort_by { |name, files| [directories(files).first, name] }
                        .map { |name, files| line(name, files) }.join("\n")
        end

        # @param root [String] the checkout
        # @return [Hash{String => Array<Array(String, String)>}] each bluebook's name to its files,
        #   each as its checkout-relative path and its text
        def declared(root)
          files = Dir.glob(File.join(root, LIBRARY, "**/*.bluebook")).map do |file|
            [file.delete_prefix("#{root}/"), File.read(file, encoding: "UTF-8")]
          end
          files.select { |_path, text| text[NAME] }.group_by { |_path, text| text[NAME, 1] }
        end

        # @param name [String] the bluebook's name
        # @param files [Array<Array(String, String)>] its files' paths and texts
        # @return [String] its list item; with no vision declared, its name and directories alone
        def line(name, files)
          places = directories(files).map { |directory| "`#{directory}/`" }.join(", ")
          vision = files.filter_map { |_path, text| text[VISION, 1] }.first
          ["- **#{name}** (#{places})", vision].compact.join(": ")
        end

        # @param files [Array<Array(String, String)>] a bluebook's files' paths and texts
        # @return [Array<String>] the directories they sit in, each once, in order
        def directories(files) = files.map { |path, _text| File.dirname(path) }.uniq.sort
      end
    end
  end
end
