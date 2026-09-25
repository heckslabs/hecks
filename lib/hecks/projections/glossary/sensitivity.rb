require_relative "../../naming"

module Hecks
  module Projections
    module Glossary
      # **The sensitive fields a glossary flags** — read from the markings a
      # deployment declares apart from the domain (`Privacy::Marking`, or a
      # `has_phi(readable_by:)` chain in a `.hecksagon`) and handed in as
      # `options[:markings]`. A marking names an aggregate by its qualified
      # name (`"Lifeadelics::Registration"`) and a field by its dotted path
      # (`"attendee.medications"`). Its category is spoken as the acronym it
      # is, uppercased and never reworded, because the category vocabulary is
      # the deployment's own and open-ended.
      module Sensitivity
        module_function

        # The markings that name one aggregate of the chapter.
        #
        # @param markings [Array<Hash{Symbol => String}>] every marking handed in, each
        #   with `:domain`, `:attribute_path`, `:category` and `:readable_by`
        # @param chapter_name [String] the chapter's declared name
        # @param aggregate [Bluebook::Aggregate] the aggregate to find markings for
        # @return [Array<Hash{Symbol => String}>] the markings whose `:domain` is
        #   `aggregate`'s qualified name, in the order they were declared
        def for_aggregate(markings, chapter_name, aggregate)
          qualified = "#{chapter_name}::#{aggregate.hecks_name}"
          markings.select { |marking| marking[:domain].to_s == qualified }
        end

        # The marked fields inside one value object, reached through whichever of
        # the aggregate's attributes holds that value object.
        #
        # @param marked [Array<Hash{Symbol => String}>] the aggregate's own markings
        # @param aggregate [Bluebook::Aggregate] the aggregate holding the value object
        # @param value_object [Bluebook::ValueObject] the value object to look inside
        # @return [Hash{String => Hash{Symbol => String}}] each marked field's name,
        #   mapped to its marking; empty when no marking reaches one of its fields
        def for_value_object(marked, aggregate, value_object)
          holders = aggregate.attributes.select { |attribute| attribute.type.to_s == value_object.hecks_name }
          holder_names = holders.map { |attribute| attribute.name.to_s }
          marked.each_with_object({}) do |marking, tagged|
            head, field, *deeper = marking[:attribute_path].to_s.split(".")
            tagged[field] = marking if field && deeper.empty? && holder_names.include?(head)
          end
        end

        # The short tag a marked field carries beside its type.
        #
        # @param marking [Hash{Symbol => String}] one marking
        # @return [String] the marking's category, uppercased
        def tag(marking) = marking[:category].to_s.upcase

        # One line of an aggregate's "Handled as sensitive" list: which field, what
        # kind of sensitive, and who may read it unredacted.
        #
        # @param marking [Hash{Symbol => String}] one marking
        # @return [String] the field's spoken path, its uppercased category, and the
        #   role that reads it unredacted, as one sentence
        def sentence(marking)
          path = marking[:attribute_path].to_s.split(".").map { |part| Naming.words(part).downcase }.join(" ")
          reader = Naming.words(marking[:readable_by]).downcase
          "#{path.sub(/\A[[:lower:]]/, &:upcase)}: #{tag(marking)}, read unredacted only by the #{reader}."
        end
      end
    end
  end
end
