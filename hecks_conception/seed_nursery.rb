#!/usr/bin/env ruby
# SeedNursery — generates Bluebook definitions for empty nursery folders
# Usage: ruby seed_nursery.rb

NURSERY = File.join(__dir__, "nursery")
VERSION = "2026.04.10.1"

def camel_case(snake)
  snake.split("_").map(&:capitalize).join
end

def singular(word)
  return word[0..-4] if word.end_with?("ies")
  return word[0..-2] if word.end_with?("s") && !word.end_with?("ss")
  word
end

def domain_role(name)
  case name
  when /farm|ranch|plantation|orchard|grove|field|paddy|bog|yard|estate/
    { primary: "crop", role: "Farmer", ops: "Harvest" }
  when /manufactur|factory|plant|mill|press|foundry|shop|assembly/
    { primary: "product", role: "Operator", ops: "Production" }
  when /mining|quarry|smelting|processing|extraction/
    { primary: "resource", role: "Operator", ops: "Extraction" }
  when /clinic|hospital|ward|care|medical|pharmacy|nursing|icu/
    { primary: "patient", role: "Clinician", ops: "Treatment" }
  when /school|academy|training|certification|seminary/
    { primary: "student", role: "Instructor", ops: "Enrollment" }
  when /court|board|commission|filing|license|registry|records/
    { primary: "case", role: "Clerk", ops: "Filing" }
  when /club|league|team|gym|studio|arena|park|rink|pool|track/
    { primary: "member", role: "Manager", ops: "Session" }
  when /lab|research|analysis|testing|monitoring|survey|study/
    { primary: "sample", role: "Researcher", ops: "Analysis" }
  when /hotel|resort|lodge|rental|hostel|inn/
    { primary: "reservation", role: "FrontDesk", ops: "Booking" }
  when /transport|shipping|freight|cargo|dock|terminal|barge|dispatch/
    { primary: "shipment", role: "Dispatcher", ops: "Transit" }
  when /conservation|restoration|ecology|refuge|sanctuary|shelter/
    { primary: "site", role: "Warden", ops: "Assessment" }
  when /insurance|bond|underwriting|compliance|audit/
    { primary: "policy", role: "Underwriter", ops: "Review" }
  when /trading|exchange|market|fund|equity|capital|finance/
    { primary: "position", role: "Trader", ops: "Transaction" }
  when /station|tower|telescope|satellite|ground/
    { primary: "system", role: "Operator", ops: "Operation" }
  when /engine|turbine|motor|reactor|generator|system/
    { primary: "unit", role: "Engineer", ops: "Operation" }
  else
    { primary: "item", role: "Manager", ops: "Operation" }
  end
end

empty_dirs = Dir.glob(File.join(NURSERY, "*")).select { |d|
  File.directory?(d) && (Dir.entries(d) - %w[. ..]).empty?
}

puts "Seeding #{empty_dirs.size} empty nursery domains..."

empty_dirs.each do |dir|
  name = File.basename(dir)
  domain = camel_case(name)
  info = domain_role(name)
  human_name = name.tr("_", " ")
  agg1 = camel_case(name.split("_").last(2).join("_"))
  agg2 = "#{info[:ops]}Record"

  bluebook = <<~BLUEBOOK
    Hecks.bluebook "#{domain}", version: "#{VERSION}" do
      vision "Manages #{human_name} operations from intake through completion"

      aggregate "#{agg1}", "A #{human_name} #{info[:primary]}" do
        attribute :name, String
        attribute :description, String
        attribute :capacity, Integer
        attribute :status, String

        command "Create#{agg1}" do
          role "#{info[:role]}"
          description "Creates a new #{human_name} #{info[:primary]}"
          attribute :name, String
          attribute :description, String
          attribute :capacity, Integer
          emits "#{agg1}Created"
          then_set :name, to: :name
          then_set :description, to: :description
          then_set :capacity, to: :capacity
        end

        command "Activate#{agg1}" do
          role "#{info[:role]}"
          description "Activates the #{human_name} #{info[:primary]}"
          emits "#{agg1}Activated"
        end

        command "Suspend#{agg1}" do
          role "#{info[:role]}"
          description "Suspends the #{human_name} #{info[:primary]}"
          emits "#{agg1}Suspended"
        end

        command "Close#{agg1}" do
          role "#{info[:role]}"
          description "Closes the #{human_name} #{info[:primary]}"
          emits "#{agg1}Closed"
        end

        lifecycle :status, default: "pending" do
          transition "Activate#{agg1}" => "active", from: "pending"
          transition "Suspend#{agg1}" => "suspended", from: "active"
          transition "Activate#{agg1}" => "active", from: "suspended"
          transition "Close#{agg1}" => "closed", from: "active"
        end
      end

      aggregate "#{agg2}", "A #{human_name} #{info[:ops].downcase} record" do
        attribute :#{info[:primary]}_id, String
        attribute :started_at, String
        attribute :completed_at, String
        attribute :notes, String
        attribute :status, String

        reference_to #{agg1}

        command "Start#{agg2}" do
          role "#{info[:role]}"
          description "Starts a new #{info[:ops].downcase} record"
          attribute :#{info[:primary]}_id, String
          attribute :notes, String
          emits "#{agg2}Started"
          then_set :#{info[:primary]}_id, to: :#{info[:primary]}_id
          then_set :notes, to: :notes
        end

        command "Complete#{agg2}" do
          role "#{info[:role]}"
          description "Completes the #{info[:ops].downcase} record"
          attribute :completed_at, String
          emits "#{agg2}Completed"
          then_set :completed_at, to: :completed_at
        end

        command "Cancel#{agg2}" do
          role "#{info[:role]}"
          description "Cancels the #{info[:ops].downcase} record"
          emits "#{agg2}Canceled"
        end

        lifecycle :status, default: "pending" do
          transition "Start#{agg2}" => "in_progress", from: "pending"
          transition "Complete#{agg2}" => "completed", from: "in_progress"
          transition "Cancel#{agg2}" => "canceled", from: "in_progress"
        end
      end

      policy "Notify#{info[:ops]}OnActivation" do
        on "#{agg1}Activated"
        trigger "Start#{agg2}"
      end
    end
  BLUEBOOK

  path = File.join(dir, "#{name}.bluebook")
  File.write(path, bluebook)
end

puts "Done. Seeded #{empty_dirs.size} domains."
