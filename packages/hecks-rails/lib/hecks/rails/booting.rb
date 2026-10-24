require "hecks"
require_relative "booted_domain"

module Hecks
  # The Rails driving adapter: a Rails app reaches its domain through thin models, routes drawn
  # from the domain's verbs and controllers with one named action per verb (ADR 0121).
  #
  # It is a driving adapter like `hecks console`, built on the core handle, and the only place
  # Rails and ActiveModel meet Hecks; nothing under `lib/hecks` requires either. Inside this
  # namespace the framework is `::Rails`, since `Rails` names this module.
  module Rails
    class << self
      # Boots the app's domain without installing the top-level Ruby modules, so the app's own
      # `Account` class is free to exist beside the `Account` aggregate.
      #
      # @param path [String] the domain directory, the app's `bluebook/`
      # @param environment [String, nil] the `environments/<name>` overlay to load; nil loads none
      # A model class already loaded has its verbs defined again from the new boot's IR.
      #
      # @return [Rails::BootedDomain] the booted domain every model, route and controller reads
      # @raise [Hecks::Refused, StandardError] whatever the boot refuses the domain with
      def boot!(path, environment: nil)
        @domain = BootedDomain.new(Hecks.boot(path, install_driving: false, environment: environment))
        Model.declared_models.each(&:define_verbs!) if defined?(Model)
        @domain
      end

      # Answers the domain the last `boot!` booted.
      #
      # @return [Rails::BootedDomain] the booted domain
      # @raise [Rails::NotBooted] if nothing booted yet
      def domain
        @domain or raise NotBooted, "no Hecks domain is booted: Hecks::Rails.boot!(path) runs first"
      end

      # Answers whether a domain is booted.
      #
      # @return [Boolean] true once `boot!` has run
      def booted? = !@domain.nil?
    end

    # Raised when a model, route or controller reads the domain before `boot!` ran.
    class NotBooted < StandardError; end
  end
end
