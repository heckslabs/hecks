# Hecks::AttachmentMethods
#
# Service mixin that adds file attachment tracking to aggregate instances.
# Bound by AggregateWiring when the aggregate is marked attachable in the DSL.
# Attachments are metadata references (name, url, content_type) — not file storage.
#
#   AttachmentMethods.bind(PizzaClass)
#   pizza = Pizza.create(name: "Margherita")
#   pizza.attach(name: "photo.jpg", url: "https://example.com/photo.jpg", content_type: "image/jpeg")
#   pizza.attachments  # => [{ name: "photo.jpg", url: "...", content_type: "image/jpeg" }]
#
module Hecks
  # Provides file attachment metadata tracking for aggregate instances.
  # This module is not included directly; instead, +.bind+ prepends
  # +InstanceMethods+ onto a target class so that every instance gains
  # an +@attachments+ array and methods to manage it.
  #
  # Attachments are lightweight metadata records (name, URL, content type).
  # Actual file storage is handled externally; this module only tracks references.
  module AttachmentMethods
    # Prepends attachment instance methods onto the given class.
    # After binding, instances of +klass+ will have +#attach+ and +#attachments+
    # methods, and +#initialize+ will set up an empty attachments array.
    #
    # @param klass [Class] the aggregate class to receive attachment methods
    # @return [void]
    def self.bind(klass)
      klass.prepend(InstanceMethods)
    end

    # Instance methods prepended onto aggregate classes by +AttachmentMethods.bind+.
    # Wraps the original +#initialize+ to set up an empty attachments array,
    # and provides +#attach+ and +#attachments+ for managing file metadata.
    module InstanceMethods
      # Initializes the aggregate instance and sets up an empty attachments list.
      # Delegates all keyword arguments to the original +#initialize+ via +super+.
      #
      # @param attrs [Hash] keyword arguments passed through to the aggregate constructor
      # @return [void]
      def initialize(**attrs)
        super(**attrs)
        @attachments = []
      end

      # Records a file attachment metadata entry on this aggregate instance.
      #
      # @param name [String] the filename or display name of the attachment
      # @param url [String] the URL where the file can be accessed
      # @param content_type [String, nil] the MIME type of the file (e.g., "image/jpeg")
      # @return [Array<Hash>] the updated attachments array
      def attach(name:, url:, content_type: nil)
        @attachments << { name: name, url: url, content_type: content_type }
      end

      # Returns a frozen copy of all attachment metadata entries.
      # The returned array is a duplicate, so modifications do not affect
      # the internal attachments list.
      #
      # @return [Array<Hash>] list of attachment hashes, each with :name, :url, and :content_type keys
      def attachments
        @attachments.dup
      end
    end
  end
end
