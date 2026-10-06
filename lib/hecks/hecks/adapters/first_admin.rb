# frozen_string_literal: true

require_relative "../../doors/json_door"

module Hecks
  module Adapters
    # Gives a booted domain its first administrator through the chapter that provides
    # `"membership"`, the way a project's hand-written bootstrap script does.
    #
    # The chapter names its own verbs (`provides "membership", admit:, grant:, people:`), so no
    # aggregate is recognised by name. Both dispatches run as a caller that asserts the role the
    # command is gated to and binds no `actor_id`: Governance checks an identified caller against
    # its role assignments, which a domain with no administrator cannot have yet, and checks an
    # unidentified one by comparing the role named (ADR 0025). That is the bootstrap step, and it is
    # refused once anyone holds an administrator role, so it cannot add a second.
    class FirstAdmin
      # The roles that count as an administrator besides the one the grant command is gated to.
      OWNER_ROLES = %w[Owner].freeze

      # What the refusal says when no chapter provides membership: the line to add to one.
      NO_MEMBERSHIP = "this domain attaches no chapter that provides \"membership\". Add a line like " \
                      "`provides \"membership\", admit: \"Person.Admit\", grant: \"Person.GrantAccess\", " \
                      "people: \"Person.All\"` to the chapter that keeps who may sign in: admit and grant " \
                      "name its commands (the grant command is gated to the administrator role), people " \
                      "names the query that lists everyone (docs/running-a-rules-service.md)"

      # What a bootstrap did.
      #
      # @!attribute [r] email
      #   @return [String] who was granted access
      # @!attribute [r] role
      #   @return [String] the role they now hold
      # @!attribute [r] admitted
      #   @return [Boolean] whether the person had to be admitted first
      Result = Struct.new(:email, :role, :admitted, keyword_init: true) do
        # @return [String] the sentence the verb answers with
        def to_s = "Granted #{role} access to #{email}#{" (admitted first)" if admitted}"
      end

      # @param runtime [Hecks::Runtime] the booted domain
      def initialize(runtime)
        @runtime = runtime
        @registry = runtime.registry
      end

      # Admits the person if they are not yet, then grants them a role.
      #
      # @param email [String] the person's email, the membership aggregate's identity
      # @param name [String, nil] their name; the part of the email before the `@` when nil
      # @param role [String, nil] the role to grant; the one the grant command is gated to when nil
      # @return [Result] what was done
      # @raise [Runtime::NotFound] when the domain has no membership chapter, the email is not an
      #   email, or an administrator already exists
      def call(email:, name: nil, role: nil)
        raise Runtime::NotFound, "#{email.inspect} is not an email address" unless email?(email)

        provider = membership_provider
        verbs, gate, people = check_unadministered(provider)

        admitted = people.none? { |person| person.dig(:email, :value) == email }
        admit(provider, verbs.fetch(:admit), email, name || email[/\A[^@]+/]) if admitted
        grant(provider, verbs.fetch(:grant), email, role || gate)
        Result.new(email: email, role: role || gate, admitted: admitted)
      end

      private

      def email?(email) = email.to_s.match?(/\A[^\s@]+@[^\s@]+\z/)

      # The membership verbs, the role the grant is gated to and the people held, once no
      # administrator is found among them.
      def check_unadministered(provider)
        verbs  = verbs_of(provider)
        gate   = gated_role(provider, verbs.fetch(:grant))
        people = rows(verbs.fetch(:people))
        refuse_if_administered!(people, [gate, *OWNER_ROLES].uniq)
        [verbs, gate, people]
      end

      def membership_provider
        domain = @registry.bluebooks.values.first&.name
        @registry.membership_provider_for(domain) or
          raise Runtime::NotFound, NO_MEMBERSHIP
      end

      def verbs_of(provider)
        %i[admit grant people].to_h { |key| [key, provider.provided_verb(Bluebook::Capabilities::MEMBERSHIP, key)] }
      end

      def rows(verb) = @runtime.query(verb).map { |row| Doors::JsonDoor.materialize(row) }

      # The role a verb's command declares, which the dispatch must assert to be let through.
      def gated_role(provider, verb)
        aggregate, command = verb.split("::").last.split(".")
        found = declared_command(provider, aggregate, command)
        found&.role&.to_s or raise Runtime::NotFound, "#{verb} declares no role to bootstrap as"
      end

      # The command the provider's aggregate declares, or nil when either is not declared.
      def declared_command(provider, aggregate, command)
        holder = provider.aggregates.find { |candidate| candidate.hecks_name == aggregate }
        holder&.commands&.find { |candidate| candidate.hecks_name == command }
      end

      def refuse_if_administered!(people, roles)
        held = people.select { |person| roles.map(&:downcase).include?(person.dig(:role, :value).to_s.downcase) }
        return if held.empty?

        who = held.map { |person| person.dig(:email, :value) }.join(", ")
        raise Runtime::NotFound, "an administrator already exists (#{who}); grant roles through the " \
                                 "domain's own #{roles.first} access instead"
      end

      def admit(provider, verb, email, name)
        as(provider, verb) do
          @runtime.dispatch(verb, with: { email: { value: email }, name: { value: name } })
        end
      end

      def grant(provider, verb, email, role)
        as(provider, verb) { @runtime.dispatch(verb, to: email, with: { role: { value: role } }) }
      end

      def as(provider, verb, &)
        Hecks.as_caller(role: gated_role(provider, verb), &)
      end
    end
  end
end
