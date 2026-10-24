module Hecks
  module Rails
    class Model
      # Which of a record's verbs an actor could run now, asked of the domain and never listed
      # beside it.
      #
      # Each verb is dry-run as the actor through the dispatcher's `dry_run?`, which runs the
      # whole pipeline in memory and keeps nothing. A verb that wants input refuses for its
      # missing input before it reads its rules, so for such a verb the actor's Governance grant
      # and the record's lifecycle state are asked directly, the same two facts the dispatch
      # would read next; a refusal about the verb's own input means "needs input", not "no".
      module Availability
        # Lists the verbs `actor` could run on this record now.
        #
        # @param as [Object, nil] the actor: anything answering `hecks_actor_id` or `id`, or the
        #   actor's identity itself; nil asks as an anonymous caller
        # @return [Array<Bluebook::Command>] the non-creating verbs that would not be refused,
        #   in declaration order; `[]` for a model with no stored record
        def available_commands(as:)
          return [] unless persisted?

          actor_id = Availability.actor_id_of(as)
          Hecks.as_caller(role: "", actor_id: actor_id, as_of: Time.now.to_i) do
            self.class.address.aggregate.commands.reject(&:creates?).select { |command| admits?(command, actor_id) }
          end
        end

        # Reads an actor's identity the way a controller's `hecks_actor_id` does.
        #
        # @param actor [Object, nil] a user object, an identity, or nil
        # @return [String, nil] the actor's identity; nil for an anonymous caller
        def self.actor_id_of(actor)
          return nil if actor.nil?
          return actor.hecks_actor_id&.to_s if actor.respond_to?(:hecks_actor_id)
          return actor.id&.to_s if actor.respond_to?(:id)

          actor.to_s
        end

        private

        def admits?(command, actor_id)
          Rails.domain.dispatcher.dry_run?("#{self.class.address.fqn}.#{command.hecks_name}", **identity_facts)
        rescue Hecks::Refused => e
          needs_input?(command, e) && role_held?(command, actor_id) && lifecycle_admits?(command)
        end

        # The record's identity as a dry run reads it: each identity field's stored value.
        def identity_facts
          heads = self.class.address.aggregate.identity_paths.map { |path| path.to_s.split(".").first.to_sym }.uniq
          heads.to_h { |head| [head, plain(self[head])] }
        end

        def plain(value) = value.respond_to?(:to_h) && !value.is_a?(Hash) ? value.to_h : value

        def needs_input?(command, refusal) = command.attributes.any? { |attribute| attribute.name.to_sym == refusal.attribute }

        def role_held?(command, actor_id)
          return true if command.role.to_s.empty?

          registry = Rails.domain.registry
          return false unless actor_id && registry.authorization_provider_for(self.class.address.chapter)

          Ports::Authorization.holds_role?(registry, actor_id: actor_id, role: command.role, as_of: Time.now.to_i)
        end

        def lifecycle_admits?(command)
          field = self.class.address.aggregate.lifecycle_field
          states = Array(command.from).map(&:to_s)
          field.nil? || states.empty? || states.include?(self[field].to_s)
        end
      end
    end
  end
end
