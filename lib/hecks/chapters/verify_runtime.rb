# Hecks::Chapters::RuntimeVerifier
#
# Boots the Pizzas domain and exercises the full pipeline:
# DSL → IR → runtime → memory adapter → command bus → event bus.
# Also verifies round-trip serialization via MigrationContract.
#
#   Hecks::Chapters::RuntimeVerifier.run
#   Hecks::Chapters::RuntimeVerifier.run(format: :documentation)
#
module Hecks
  module Chapters
    module RuntimeVerifier
      Result = Struct.new(:pass_count, :errors)

      def self.run(format: :progress)
        result = Result.new(0, [])

        puts "\e[1mRuntime (Pizzas)\e[0m" if format == :documentation

        app = Hecks.boot(pizzas_dir)

        verify_boot(result, format, app)
        verify_create(result, format, app)
        verify_collection(result, format, app)
        verify_lifecycle(result, format, app)
        verify_query(result, format, app)
        verify_events(result, format, app)
        verify_round_trip(result, format, app)

        puts "" if format == :documentation
        result
      end

      def self.pizzas_dir
        File.join(Dir.pwd, "examples/pizzas")
      end

      def self.verify_boot(result, format, app)
        check(result, format, "Boot", "domain loads") do
          raise "no domain" unless app.domain
          raise "wrong name" unless app.domain.name == "Pizzas"
        end

        check(result, format, "Boot", "aggregates present") do
          names = app.domain.aggregates.map(&:name)
          raise "missing Pizza" unless names.include?("Pizza")
          raise "missing Order" unless names.include?("Order")
        end
      end

      def self.verify_create(result, format, app)
        check(result, format, "Create", "Pizza.create") do
          as_role("Chef")
          pizza = Pizza.create(name: "Verify", description: "Test pizza")
          raise "nil aggregate" unless pizza
          raise "wrong name" unless pizza.name == "Verify"
        end

        check(result, format, "Create", "Pizza.find") do
          as_role("Chef")
          pizza = Pizza.create(name: "Findable", description: "Test")
          found = Pizza.find(pizza.id)
          raise "not found" unless found
          raise "name mismatch" unless found.name == "Findable"
        end
      end

      def self.verify_collection(result, format, app)
        check(result, format, "Collection", "pizza.toppings.create") do
          as_role("Chef")
          pizza = Pizza.create(name: "Topped", description: "Test")
          pizza.toppings.create(name: "Cheese", amount: 1)
          found = Pizza.find(pizza.id)
          raise "no toppings" unless found.toppings.count >= 1
        end

        check(result, format, "Collection", "name not overwritten") do
          as_role("Chef")
          pizza = Pizza.create(name: "Original", description: "Test")
          pizza.toppings.create(name: "Sauce", amount: 2)
          found = Pizza.find(pizza.id)
          raise "name was overwritten: #{found.name}" unless found.name == "Original"
        end
      end

      def self.verify_lifecycle(result, format, app)
        check(result, format, "Lifecycle", "Order.place → pending") do
          as_role("Customer")
          order = Order.place(customer_name: "Test", quantity: 1)
          raise "wrong status: #{order.status}" unless order.status == "pending"
        end

        check(result, format, "Lifecycle", "Order.cancel → cancelled") do
          as_role("Customer")
          order = Order.place(customer_name: "Test", quantity: 1)
          Order.cancel(order: order.id)
          found = Order.find(order.id)
          raise "wrong status: #{found.status}" unless found.status == "cancelled"
        end
      end

      def self.verify_query(result, format, app)
        check(result, format, "Query", "Pizza.by_description") do
          as_role("Chef")
          Pizza.create(name: "Queried", description: "unique_test_desc")
          results = Pizza.by_description("unique_test_desc")
          raise "no results" unless results.any?
        end

        check(result, format, "Query", "Order.pending") do
          as_role("Customer")
          Order.place(customer_name: "PendingTest", quantity: 1)
          results = Order.pending
          raise "no results" unless results.any?
        end
      end

      def self.verify_events(result, format, app)
        check(result, format, "Events", "events emitted") do
          raise "no events" unless app.events.any?
        end

        check(result, format, "Events", "event has occurred_at") do
          event = app.events.last
          raise "no occurred_at" unless event.respond_to?(:occurred_at)
          raise "nil occurred_at" unless event.occurred_at
        end
      end

      def self.verify_round_trip(result, format, app)
        check(result, format, "Serialization", "DslSerializer round-trip") do
          original = app.domain
          dsl_source = Hecks::DslSerializer.new(original).serialize
          restored = Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants { eval(dsl_source) }
          diff = Hecks::Conventions::MigrationContract.diff(original, restored)
          unless diff[:valid]
            raise "round-trip failed: #{diff[:issues].join(', ')}"
          end
        end
      end

      def self.as_role(name)
        Hecks.current_role = name
        Hecks.actor = OpenStruct.new(role: name)
      end

      def self.check(result, format, group, label)
        yield
        result.pass_count += 1
        if format == :documentation
          puts "  \e[32m✓\e[0m #{group}: #{label}"
        else
          print "."
        end
      rescue => e
        result.errors << { context: "Runtime/#{group}", message: "#{label}: #{e.message}" }
        if format == :documentation
          puts "  \e[31m✗\e[0m #{group}: #{label} — #{e.message}"
        else
          print "\e[31mF\e[0m"
        end
      end
    end
  end
end
