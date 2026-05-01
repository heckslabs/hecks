# = Hecks::Chapters::Extensions::Messaging
#
# Self-describing sub-chapter for messaging extensions:
# Slack notifications, outbox pattern for reliable delivery.
#
#   Hecks::Chapters::Extensions::Messaging.define(builder)
#
module Hecks
  module Chapters
    module Extensions
      # Hecks::Chapters::Extensions::Messaging
      #
      # Bluebook sub-chapter for messaging extensions: Slack notifications and outbox pattern.
      #
      module Messaging
        def self.define(b)
          b.aggregate "Slack", "Slack notification integration" do
            command("Notify") { attribute :channel, String; attribute :message, String }
          end

          b.aggregate "OutboxExtension", "Outbox pattern for reliable messaging" do
            command("Enqueue") { attribute :message, String }
            command("Poll") { attribute :batch_size, Integer }
          end
        end
      end
    end
  end
end
