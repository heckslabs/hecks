module Hecks

  # Hecks::RuntimeAttributeDefinition
  #
  # Value object representing a declared attribute on a runtime model class.
  # Replaces plain hashes `{ name:, default:, freeze: }` with a proper struct
  # that supports both method access and hash-style [] access.
  #
  #   attr_def = RuntimeAttributeDefinition.new(name: :title, default: nil, freeze: false)
  #   attr_def.name     # => :title
  #   attr_def[:name]   # => :title (hash-style access)
  #   attr_def.default  # => nil
  #   attr_def[:freeze] # => false
  #
  RuntimeAttributeDefinition = Struct.new(:name, :default, :freeze, keyword_init: true)
end
