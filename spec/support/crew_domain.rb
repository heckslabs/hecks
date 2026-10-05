require "fileutils"

# A throwaway domain whose chapter provides "membership": a `Crew` of people who may sign in,
# gated to the role "Admin", bound to Memory and attached to Governance and Identity.
module CrewDomain
  BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Crew" do
      vision "A crew that may sign in."
      provides "membership", admit: "Person.Admit", grant: "Person.GrantAccess", people: "Person.All"

      aggregate "Person" do
        description "One admitted person."
        identified_by :email
        attribute :email, Email
        attribute :name, PersonName
        attribute :role, Role, optional: true
        value_object("Email") { attribute :value, String }
        value_object("PersonName") { attribute :value, String }
        value_object("Role") { attribute :value, String }

        command "Admit" do
          role "Admin"
          goal "Admit a person"
          attribute :email, Email
          attribute :name, PersonName
          sets :email
          sets :name
          emits "PersonAdmitted"
        end

        command "GrantAccess" do
          role "Admin"
          goal "Let a person sign in with a role"
          reference_to Person
          attribute :role, Role
          sets :role
          emits "PersonAccessGranted"
        end

        query "All" do
          description "Everyone admitted."
          order_by "name.value"
        end
      end
    end
  RUBY

  HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Crew" do
      attaches "Governance"
      attaches "Identity"
      Crew::Person.persisted_by("Memory")
    end

    Hecks.hecksagon "Governance" do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end

    Hecks.hecksagon "Identity" do
      attaches "Governance"
      Identity::Identity.persisted_by("Memory")
      Identity::ExternalIdentifier.persisted_by("Memory")
    end
  RUBY

  # Writes the domain under a directory.
  #
  # @param dir [String] where the domain's files go
  # @param sqlite [String, nil] a database file; the domain keeps its records there, so a second
  #   boot sees them, instead of in Memory
  # @return [String] the directory
  def self.write(dir, sqlite: nil)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "crew.bluebook"), BLUEBOOK)
    File.write(File.join(dir, "crew.hecksagon"), sqlite ? HECKSAGON.gsub("Memory", "SqlitePersistence") : HECKSAGON)
    File.write(File.join(dir, "crew.world"), world(sqlite)) if sqlite
    dir
  end

  # @param database [String] the database file
  # @return [String] a world binding every aggregate to Sqlite at `database`
  def self.world(database)
    <<~RUBY
      Hecks.world "Crew" do
        realm "Specs"
        default_adapter "SqlitePersistence"
        default_database #{database.inspect}
      end
    RUBY
  end
end
