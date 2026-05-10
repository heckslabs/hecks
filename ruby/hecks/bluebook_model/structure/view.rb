module Hecks
  module BluebookModel
    module Structure

    # Hecks::BluebookModel::Structure::View
    #
    # Named projection of an aggregate's fields, scoped by role (i254).
    # Mirrors the Rust IR `View` struct. Different portals consume the
    # same aggregate through different views — the customer's pickup
    # row exposes scheduled_date / status / photos, the admin's view
    # of the same pickup also exposes worker_account_email / route_id /
    # failed_reason / internal_notes. The view declaration is the
    # single source of truth ; portals fetch by name.
    #
    #   View.new(name: "for_customer", show_all: false,
    #            fields: [:scheduled_date, :status, :before_photo,
    #                     :after_photo, :completed_at])
    #
    #   View.new(name: "for_admin", show_all: true,
    #            fields: [:route_id, :worker_account_email,
    #                     :failed_reason, :internal_notes])
    #
    # `show_all: true` projects every aggregate attribute, then
    # appends `fields` as extras. `show_all: false` projects only
    # the explicit `fields` list.
    class View
      # @return [String] the view name (e.g., "for_customer", "for_admin")
      attr_reader :name

      # @return [Boolean] true if the view should include every aggregate
      #   attribute (then append `fields` as extras) ; false if only the
      #   explicit `fields` list is projected.
      attr_reader :show_all

      # @return [Array<Symbol>] ordered list of projected field names.
      #   Symbols are stored in original declaration order ; the
      #   canonical_ir dumper stringifies them when emitting JSON so
      #   parity with Rust's Vec<String> stays byte-identical.
      attr_reader :fields

      def initialize(name:, show_all: false, fields: [])
        @name = name.to_s
        @show_all = !!show_all
        @fields = fields.map(&:to_sym)
      end

      def show_all?
        @show_all
      end

      # Resolve this view against a record's attribute hash. Returns a
      # Hash of field-name → value pairs in projection order. When
      # `show_all` is true, every key in `attrs` is included first
      # (in attribute-declaration order if `attribute_order` is given,
      # otherwise insertion order), then the explicit `fields` list
      # is appended (deduped).
      #
      # @param attrs [Hash] the record's attributes
      # @param attribute_order [Array<Symbol>, nil] optional canonical
      #   attribute order (typically the aggregate's declared attribute
      #   list) — used to make show_all stable across hash insertion
      #   variations
      # @return [Hash] projected attributes in view order
      def project(attrs, attribute_order: nil)
        out = {}
        if @show_all
          base = attribute_order || attrs.keys
          base.each do |k|
            sym = k.to_sym
            out[sym] = attrs[sym] if attrs.key?(sym) || attrs.key?(sym.to_s)
            out[sym] ||= attrs[sym.to_s] if attrs.key?(sym.to_s)
          end
        end
        @fields.each do |f|
          next if out.key?(f)
          if attrs.key?(f)
            out[f] = attrs[f]
          elsif attrs.key?(f.to_s)
            out[f] = attrs[f.to_s]
          else
            out[f] = nil
          end
        end
        out
      end
    end

    end
  end
end
