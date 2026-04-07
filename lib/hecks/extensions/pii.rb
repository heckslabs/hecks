# Hecks::PII
#
# PII (Personally Identifiable Information) protection extension for Hecks
# domains. Reads +pii: true+ markers on aggregate attributes and provides
# masking, redaction, and GDPR-compliant erasure capabilities.
#
# When registered, this extension adds two methods to the domain module:
# - +erase_pii(entity_id)+ -- nullifies all PII fields on the entity across
#   all aggregates (for GDPR right-to-erasure compliance)
# - +pii_fields+ -- returns a hash mapping aggregate names to their PII
#   field names for introspection
#
# When the audit extension is also loaded, PII values in audit log entries
# are automatically masked via command bus middleware.
#
# Future gem: hecks_pii
#
#   # DSL
#   attribute :email, String, pii: true
#
#   # Gemfile
#   gem "cats_domain"
#   gem "hecks_pii"
#
#   # Erasure
#   CatsDomain.erase_pii(customer_id)
#
module Hecks; end
# Hecks::PII
#
# PII protection extension providing masking, redaction, and GDPR-compliant erasure for pii-tagged attributes.
#
module Hecks::PII
  # Mask a string value for display, preserving the first and last characters
  # and replacing all middle characters with asterisks. Returns "[REDACTED]"
  # for strings shorter than 4 characters.
  #
  # @param value [String, nil] the value to mask
  # @return [String, nil] the masked string, or nil if value was nil
  #
  # @example
  #   Hecks::PII.mask("john@example.com")  # => "j**************m"
  #   Hecks::PII.mask("Jo")                # => "[REDACTED]"
  #   Hecks::PII.mask(nil)                 # => nil
  def self.mask(value)
    return nil if value.nil?
    s = value.to_s
    return "[REDACTED]" if s.length < 4
    "#{s[0]}#{"*" * (s.length - 2)}#{s[-1]}"
  end

  # Return an array of attribute names marked as PII on the given aggregate.
  #
  # Filters the aggregate's attributes by the +pii?+ predicate and extracts
  # their symbolic names.
  #
  # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the aggregate
  #   definition whose attributes are inspected
  # @return [Array<Symbol>] names of attributes marked with +pii: true+
  def self.pii_fields(aggregate)
    aggregate.attributes.select(&:pii?).map(&:name)
  end
end

Hecks.describe_extension(:pii,
  description: "PII field encryption and masking",
  adapter_type: :driven,
  config: {},
  wires_to: :repository)

Hecks.register_extension(:pii) do |domain_mod, domain, runtime|
  # Add erase_pii method to domain module.
  #
  # Iterates all aggregates, finds those with PII fields, locates the entity
  # by ID, and saves a new instance with all PII fields set to nil. This
  # implements GDPR right-to-erasure by nullifying PII data in-place.
  #
  # @param entity_id [String] the ID of the entity to erase PII from
  # @return [void]
  domain_mod.define_singleton_method(:erase_pii) do |entity_id|
    domain.aggregates.each do |agg|
      pii_names = Hecks::PII.pii_fields(agg)
      next if pii_names.empty?

      repo = runtime[agg.name]
      entity = repo.find(entity_id)
      next unless entity

      nulled_attrs = {}
      pii_names.each { |name| nulled_attrs[name] = nil }
      agg_class = domain_mod.const_get(agg.name)
      erased = agg_class.new(id: entity.id, **nulled_attrs)
      repo.save(erased)
    end
  end

  # Add pii_fields introspection to domain module.
  #
  # Returns a hash mapping aggregate names (as symbols) to arrays of PII
  # field names. Only includes aggregates that have at least one PII field.
  #
  # @return [Hash{Symbol => Array<Symbol>}] aggregate name to PII field names
  domain_mod.define_singleton_method(:pii_fields) do
    domain.aggregates.each_with_object({}) do |agg, h|
      fields = Hecks::PII.pii_fields(agg)
      h[agg.name] = fields unless fields.empty?
    end
  end

  # Patch audit extension to mask PII if both extensions are loaded.
  #
  # When the audit extension is registered, this adds a :pii_mask middleware
  # that runs after each command. It checks if the command's aggregate has
  # PII fields, and if so, masks those values in the most recent audit log
  # entry to prevent PII from appearing in audit trails.
  if Hecks.extension_registry[:audit]
    pii_lookup = {}
    domain.aggregates.each do |agg|
      agg.commands.each do |cmd|
        fqn = Hecks::Conventions::Names.domain_command_fqn(domain_mod.name, agg.name, cmd.name)
        pii_names = Hecks::PII.pii_fields(agg)
        pii_lookup[fqn] = pii_names unless pii_names.empty?
      end
    end

    runtime.use :pii_mask do |command, next_handler|
      result = next_handler.call
      pii_names = pii_lookup[command.class.name]
      if pii_names && domain_mod.respond_to?(:audit_log)
        entry = domain_mod.audit_log.last
        if entry && entry[:attributes]
          pii_names.each do |name|
            entry[:attributes][name] = Hecks::PII.mask(entry[:attributes][name]) if entry[:attributes].key?(name)
          end
        end
      end
      result
    end
  end
end
