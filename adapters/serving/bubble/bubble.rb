# HecksBubble
#
# Anti-Corruption Layer (ACL) extension for Hecks domains. Defines
# translation contexts that map legacy or external system data into
# clean domain commands. Each context declares field renames, value
# transforms, and optional reverse mappings for outbound translation.
#
# Usage:
#   require "hecks/extensions/bubble"
#
#   ctx = HecksBubble::Context.new do
#     map_aggregate :Pizza do
#       from_legacy :create,
#         rename: { pizza_nm: :name, desc_text: :description },
#         transform: { name: ->(v) { v.strip.capitalize } }
#
#       map_out :create,
#         rename: { name: :pizza_nm, description: :desc_text }
#     end
#   end
#
#   ctx.translate(:Pizza, :create, pizza_nm: " margherita ", desc_text: "Classic")
#   # => { name: "Margherita", description: "Classic" }
#
#   ctx.reverse(:Pizza, :create, name: "Margherita", description: "Classic")
#   # => { pizza_nm: "Margherita", desc_text: "Classic" }
#
module HecksBubble
  # A single inbound mapping: field renames + optional value transforms.
  #
  # @attr_reader rename [Hash{Symbol => Symbol}] legacy key to domain key
  # @attr_reader transform [Hash{Symbol => Proc}] domain key to transform proc
  Mapping = Struct.new(:rename, :transform, keyword_init: true) do
    def initialize(rename: {}, transform: {})
      super(rename: rename, transform: transform)
    end
  end

  # A single outbound mapping: domain keys back to legacy keys.
  #
  # @attr_reader rename [Hash{Symbol => Symbol}] domain key to legacy key
  OutMapping = Struct.new(:rename, keyword_init: true) do
    def initialize(rename: {})
      super(rename: rename)
    end
  end
end

Hecks::Chapters.load_aggregates(
  Hecks::Extensions::BubbleChapter,
  base_dir: File.expand_path("bubble", __dir__)
)

Hecks.describe_extension(:bubble,
  description: "Anti-corruption layer for legacy data translation",
  adapter_type: :driven,
  config: {},
  wires_to: :commands)

Hecks.register_extension(:bubble) do |domain_mod, _domain, _runtime|
  domain_mod.define_singleton_method(:bubble_context) do |&block|
    @_bubble_context = HecksBubble::Context.new(&block)
  end

  domain_mod.define_singleton_method(:bubble) do
    @_bubble_context
  end
end
