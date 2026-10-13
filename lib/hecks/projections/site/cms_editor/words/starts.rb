# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        module Words
          # Gives each member of a family the start of the page it makes. When the family's `titles`
          # aggregate has a creating command, a new member's form asks for the page's title and address
          # first, in the same form, and the editor makes the `titles` record and then the member (key
          # `<kind>:<address>`). Without it a new page is two steps, the detail first and then its type.
          # A member whose creating command takes no key, or a `titles` aggregate with no title, is left
          # as it was.
          module Starts
            # The attributes of a `titles` aggregate's creating command that name a page to a person.
            NAMERS = %w[title name label].freeze

            module_function

            # @param members [Array<Hash{String => Object}>] the family's member aggregates, changed in place
            # @param titles [Hash{String => Object}, nil] the aggregate that titles them
            # @param kind [String] what the member's key starts with (`page` for `page:<address>`)
            # @return [void]
            def apply(members, titles, kind)
              made = titles && titles["commands"].find { |command| command["creates"] }
              shown = made && shown_by(titles, made)
              return unless shown

              members.each { |member| start(member, titles, made, shown, kind) }
            end

            # @return [Array<Hash{String => Object}>, nil] the title attribute and the identity attribute
            #   of the creating command, or nil when it has no title
            def shown_by(titles, made)
              named = made["attributes"].find { |attr| namer?(attr) }
              identity = made["attributes"].find { |attr| attr["name"] == titles["identity"] }
              named && identity ? [named, identity] : nil
            end

            def namer?(attr) = NAMERS.include?(attr["name"]) && !attr["list"] && attr["widget"] != "body"

            def start(member, titles, made, shown, kind)
              creating = member["commands"].find { |command| keyed?(command, member) }
              return unless creating && free?(creating, member, shown)

              rest = creating["attributes"].reject { |attr| key?(attr, member) }
              creating["attributes"] = [*shown.map { |attr| copy(attr) }, *rest]
              creating["starts"] = starts(member, titles, made, shown, kind)
              adopt(member, titles, shown)
            end

            # @return [Hash{String => Object}] what the editor reads to make the page's record first
            def starts(member, titles, made, shown, kind)
              { "aggregate" => keyed(titles), "command" => made["name"], "identity" => shown.last["name"],
                "key" => member["identity"], "kind" => kind, "keep" => shown.map { |attr| attr["name"] } }
            end

            # @return [Boolean] whether a command makes a record and takes its key
            def keyed?(command, member) = command["creates"] && command["attributes"].any? { |attr| key?(attr, member) }

            def key?(attr, member) = attr["name"] == member["identity"]

            # @return [Boolean] whether none of the copied attributes would take a name the command has
            def free?(command, member, shown)
              names = command["attributes"].reject { |attr| key?(attr, member) }.map { |attr| attr["name"] }
              !names.intersect?(shown.map { |attr| attr["name"] })
            end

            # A copy of the titles command's attribute, marked so it is a new value and not a choice.
            def copy(attr) = Marshal.load(Marshal.dump(attr)).merge("starts" => true)

            # The value objects the copied attributes are of, which the member's form is read against.
            def adopt(member, titles, shown)
              shown.each do |attr|
                held = titles["valueObjects"][attr["type"]]
                member["valueObjects"][attr["type"]] ||= held if held
              end
            end

            # What `names.ts` calls an aggregate: the chapter and name when the editor spans several.
            def keyed(agg) = agg["chapter"] ? "#{agg["chapter"]}.#{agg["name"]}" : agg["name"]
          end
        end
      end
    end
  end
end
