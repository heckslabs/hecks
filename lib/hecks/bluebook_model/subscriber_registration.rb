module Hecks
  module BluebookModel

    # Hecks::BluebookModel::SubscriberRegistration
    #
    # Value object representing a domain-level event subscriber registration.
    # Replaces plain hashes `{ event_name:, block: }` with a proper struct
    # that supports both method access and hash-style [] access.
    #
    # Part of the BluebookModel IR layer. Built by BluebookBuilder's `on_event`
    # method, consumed by Runtime::SubscriberSetup.
    #
    #   reg = SubscriberRegistration.new(event_name: "CreatedPizza", block: -> (e) { ... })
    #   reg.event_name  # => "CreatedPizza"
    #   reg.block       # => #<Proc>
    #
    SubscriberRegistration = Struct.new(:event_name, :block, keyword_init: true)
  end
end
