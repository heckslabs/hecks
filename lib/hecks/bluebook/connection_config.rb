# Hecks::ConnectionConfig
#
# Value objects for domain connection configuration.
#
module Hecks
  PersistConfig = Struct.new(:type, :options, keyword_init: true) do
    def initialize(type:, **options)
      super(type: type, options: options)
    end
  end

  SendConfig = Struct.new(:name, :handler, :options, keyword_init: true) do
    def initialize(name:, handler: nil, **options)
      super(name: name, handler: handler, options: options)
    end
  end

  ExtensionConfig = Struct.new(:name, :options, keyword_init: true) do
    def initialize(name:, **options)
      super(name: name, options: options)
    end
  end
end
