#!/usr/bin/env ruby
#
# Example: Building and using a Bookshelf domain with Hecks
#
# Run from the hecks project root:
#   ruby -Ilib examples/bookshelf/app.rb

require "hecks"

# Boot the domain — loads, validates, builds, and wires everything in one call
app = Hecks.boot(__dir__)

# Subscribe to events
app.on("AddedBook") do |event|
  puts "  [event] AddedBook: #{event.title} by #{event.author}"
end

app.on("CheckedOutBook") do |event|
  puts "  [event] CheckedOutBook: status=#{event.status}"
end

app.on("ReturnedBook") do |event|
  puts "  [event] ReturnedBook: status=#{event.status}"
end

app.on("CreatedLoan") do |event|
  puts "  [event] CreatedLoan: borrower=#{event.borrower_name}, due=#{event.due_date}"
end

app.on("ClosedLoan") do |event|
  puts "  [event] ClosedLoan: status=#{event.status}"
end

# --- Add books ---
puts "\n--- Adding books ---"
moby   = Book.add(title: "Moby-Dick",             author: "Herman Melville")
gatsby = Book.add(title: "The Great Gatsby",       author: "F. Scott Fitzgerald")
dune   = Book.add(title: "Dune",                  author: "Frank Herbert")
fk     = Book.add(title: "Flowers for Algernon",  author: "Daniel Keyes")

puts "Total books: #{Book.count}"
Book.all.each { |b| puts "  #{b.title} — #{b.status}" }

# --- Check out books ---
puts "\n--- Checking out books ---"
Book.check_out(book: moby.id)
Book.check_out(book: gatsby.id)
moby   = Book.find(moby.id)
gatsby = Book.find(gatsby.id)
puts "Moby-Dick status:        #{moby.status}"
puts "The Great Gatsby status: #{gatsby.status}"

# --- Query available books ---
puts "\n--- Available books ---"
available = Book.available
puts "Available (#{available.count}): #{available.map(&:title).join(", ")}"

# --- Query by author ---
puts "\n--- Query by author ---"
results = Book.by_author("Frank Herbert")
puts "Books by Frank Herbert: #{results.map(&:title).join(", ")}"

# --- Create loans ---
puts "\n--- Creating loans ---"
loan1 = Loan.create(book: moby.id,   borrower_name: "Alice", due_date: "2026-04-15")
loan2 = Loan.create(book: gatsby.id, borrower_name: "Bob",   due_date: "2026-04-20")
puts "Active loans: #{Loan.active.count}"

# --- Return a book ---
puts "\n--- Returning a book ---"
Book.return(book: moby.id)
moby = Book.find(moby.id)
puts "Moby-Dick status after return: #{moby.status}"

Loan.close(loan: loan1.id)
puts "Active loans after return: #{Loan.active.count}"

# --- Final state ---
puts "\n--- Final state ---"
puts "Total books:     #{Book.count}"
puts "Total loans:     #{Loan.count}"
puts "Available books: #{Book.available.count}"
puts "Active loans:    #{Loan.active.count}"

puts "\n--- Event history ---"
app.events.each_with_index do |event, i|
  name = event.class.name.split("::").last
  puts "  #{i + 1}. #{name} at #{event.occurred_at}"
end
