# Hecks::Chapters::Rails
#
# Self-describing chapter definition for the hecks_on_rails gem.
# Enumerates every class and module under hecks_on_rails/lib/ as
# aggregates with their key commands.
#
#   domain = Hecks::Chapters::Rails.definition
#   domain.aggregates.map(&:name)
#   # => ["ActiveHecks", "DomainModelCompat", "AggregateCompat", ...]
#
require "bluebook"

module Hecks
  module Chapters
    module Rails
      def self.definition
        Hecks::DSL::DomainBuilder.new("Rails").tap { |b|
          b.aggregate "ActiveHecks" do
            description "Adds full ActiveModel compatibility to generated domain objects for Rails"
            command "Activate" do
              attribute :domain_module, String
            end
          end

          b.aggregate "DomainModelCompat" do
            description "Shared ActiveModel compatibility: naming, conversion, JSON serialization"
            command "Include"
          end

          b.aggregate "AggregateCompat" do
            description "Aggregate-specific ActiveModel mixin: identity, validations, lifecycle callbacks"
            command "Include"
          end

          b.aggregate "ValueObjectCompat" do
            description "Value object-specific mixin: no identity, immutable semantics"
            command "Include"
          end

          b.aggregate "ValidationWiring" do
            description "Converts DSL validation rules into ActiveModel validates calls"
            command "Bind" do
              attribute :klass, String
            end
          end

          b.aggregate "PersistenceWrapper" do
            description "Wraps save/destroy with validation checks and lifecycle callbacks"
            command "Bind" do
              attribute :klass, String
            end
          end

          b.aggregate "Railtie" do
            description "Rails integration hook: boots Hecks after initializers, provides rake tasks"
            command "Boot"
          end

          b.aggregate "InitGenerator" do
            description "Rails generator that sets up a Hecks domain gem in a Rails app"
            command "Generate"
          end

          b.aggregate "MigrationGenerator" do
            description "Rails generator that produces SQL migration files from domain changes"
            command "Generate"
          end
        }.build
      end
    end
  end
end
