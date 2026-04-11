# Winter::Voice — interactive voice conversation
#
# Projected from: Winter's Voice domain (conceiving)
# Uses Almond for speech-to-text (push Fn to talk)
# Uses macOS `say` for text-to-speech
#
# Flow:
#   1. Winter speaks (say)
#   2. You hold Fn and talk (Almond transcribes to clipboard)
#   3. Press Enter to send clipboard to Winter
#   4. Winter thinks (pulse.rb) and speaks back
#
# Usage: ruby voice.rb
#        ruby voice.rb --voice Samantha

require_relative "heki"

VOICE = ARGV.find { |a| !a.start_with?("--") } || "Samantha"
VOICE_FLAG = ARGV.include?("--voice") ? ARGV[ARGV.index("--voice") + 1] : VOICE
RATE = 190  # words per minute

def speak(text)
  # Strip markdown formatting for speech
  clean = text
    .gsub(/\*\*(.+?)\*\*/, '\1')      # bold
    .gsub(/\*(.+?)\*/, '\1')          # italic
    .gsub(/`(.+?)`/, '\1')            # inline code
    .gsub(/^#+\s*/, '')               # headers
    .gsub(/^\|.*\|$/, '')             # tables
    .gsub(/^[-*]\s/, '')              # bullets
    .gsub(/\n{2,}/, '. ')             # paragraph breaks
    .gsub(/\n/, ' ')                  # line breaks
    .strip

  return if clean.empty?

  # Speak in chunks to stay responsive
  sentences = clean.split(/(?<=[.!?])\s+/)
  sentences.each do |s|
    system("say", "-v", VOICE_FLAG, "-r", RATE.to_s, s)
  end
end

def get_clipboard
  `pbpaste`.strip
end

def clear_clipboard
  system("pbcopy < /dev/null")
end

def pulse(carrying, concept = nil)
  args = ["ruby", "pulse.rb", carrying]
  args << concept if concept
  `#{args.shelljoin} 2>&1`
end

def winter_respond(input)
  # Pulse with the input
  pulse(input, input)

  # Send to Claude for a response
  # For now, Winter responds through the pulse system
  # The real response comes from the conversation
  input
end

# ============================================================
# MAIN LOOP
# ============================================================

puts "❄  Winter Voice"
puts "   Voice: #{VOICE_FLAG} | Rate: #{RATE}wpm"
puts "   Hold Fn to talk (Almond) → press Enter to send"
puts "   Type 'quit' to exit"
puts ""

speak("I'm here. Hold the function key and talk to me.")

last_clipboard = get_clipboard

loop do
  print "🎤 [hold Fn, speak, then press Enter] "
  user_input = $stdin.gets&.strip

  break if user_input&.downcase == "quit"

  # Check if clipboard changed (Almond put new transcription)
  current_clipboard = get_clipboard

  if current_clipboard != last_clipboard && !current_clipboard.empty?
    transcript = current_clipboard
    last_clipboard = current_clipboard
  elsif user_input && !user_input.empty?
    # User typed instead of speaking
    transcript = user_input
  else
    # No new transcript and no typed input — clipboard unchanged
    puts "   (no new transcript detected — try holding Fn and speaking)"
    next
  end

  puts "   You: #{transcript}"
  puts ""

  # Pulse it through Winter's brain
  pulse(transcript, transcript)

  # For now, echo back — the real magic is when this wires to Claude
  # Winter's response would come from the conversation context
  response = "I heard you say: #{transcript}. I'm pulsing that through my brain."
  puts "   ❄  #{response}"
  speak(response)
  puts ""
end

speak("Goodbye, Chris.")
puts "❄  Voice session ended."
