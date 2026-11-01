# frozen_string_literal: true

require_relative "ticket"

module Hecks
  module Adapters
    class GitLanding
      # The numbers the line's tickets are named by: a counter kept in a file that only grows, so a
      # ticket never gets a number an earlier one had, even after the line empties.
      #
      # Ordinary numbers are a thousand apart, so a train can take the place right behind the
      # front.
      class Numbering
        # The distance between two ordinary ticket numbers.
        GAP = 1000

        # What a branch name loses before it goes into a file name.
        UNSAFE = /[^A-Za-z0-9._-]/

        # @param dir [String] the directory the tickets live in
        # @param root [String] the directory the counter lives in
        def initialize(dir, root)
          @dir = dir
          @counter = File.join(root, "sequence")
        end

        # @param tickets [Array<Ticket>] the tickets in the line, in order
        # @param branch [String] the branch the new ticket stands for
        # @param jump [Boolean] take the place right behind the front ticket
        # @param now [Time] the current time
        # @return [String] the path of the new ticket's file
        def path(tickets, branch, jump, now)
          number = jump && tickets.first ? behind(tickets) : bump
          name = "#{number.to_s.rjust(10, "0")}-#{branch.gsub(UNSAFE, "_")}-#{Process.pid}-#{now.to_i}#{Ticket::SUFFIX}"
          File.join(@dir, name)
        end

        private

        def behind(tickets)
          taken = tickets.map(&:sequence)
          first = tickets.first.sequence + 1
          (first..).find { |number| !taken.include?(number) }
        end

        def bump
          count = (File.exist?(@counter) ? File.read(@counter).to_i : 0) + GAP
          File.write(@counter, count.to_s)
          count
        end
      end
    end
  end
end
