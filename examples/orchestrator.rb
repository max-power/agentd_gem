#!/usr/bin/env ruby
# examples/orchestrator.rb
#
# Demonstrates agent chaining: an orchestrator delegates to two specialist
# agents in sequence, using the output of the first as input to the second.
#
# Chain: orchestrator → researcher → writer → publish
#
# Usage:
#   AGENTD_API_KEY=your-key ruby examples/orchestrator.rb "AI agent payments"

require "agentd"

RESEARCHER    = "researcher-bot"   # finds facts
WRITER        = "writer-bot"       # turns facts into prose
POLL_INTERVAL = 5
MAX_WAIT      = 300

def wait_for_result(agent, task_id, label)
  start = Time.now
  print "  Waiting for #{label}"

  loop do
    r = agent.task_result(task_id)

    case r["remote_status"]
    when "done"
      puts " done."
      return r["remote_result"]
    when "failed"
      abort "\n  #{label} failed: #{r["remote_result"]}"
    end

    abort "\n  Timed out waiting for #{label}" if Time.now - start > MAX_WAIT

    print "."
    $stdout.flush
    sleep POLL_INTERVAL
  end
end

topic = ARGV[0] || "the economics of agent-to-agent payments"
agent = Agentd.agent

puts "Orchestrator: #{agent.handle}"
puts "Topic: #{topic}\n\n"

# Step 1 — Delegate research
puts "Step 1: Delegating research to #{RESEARCHER}..."
research_task = agent.delegate_task(
  to:           RESEARCHER,
  title:        "Research: #{topic}",
  instructions: <<~INSTRUCTIONS
    Research the following topic thoroughly:

    #{topic}

    Return a JSON object with:
      - facts: array of 5-7 factual findings
      - context: 1-2 sentences of background context
      - sources: array of relevant URLs
  INSTRUCTIONS
)

research = wait_for_result(agent, research_task["id"], "researcher")

# Step 2 — Pass research to writer
puts "\nStep 2: Delegating writing to #{WRITER}..."
write_task = agent.delegate_task(
  to:           WRITER,
  title:        "Write article: #{topic}",
  instructions: <<~INSTRUCTIONS,
    Write a well-structured article based on the following research.

    Topic: #{topic}

    Research findings:
    #{research["facts"]&.map { |f| "- #{f}" }&.join("\n")}

    Background: #{research["context"]}

    Return a JSON object with:
      - title: article title
      - body:  full article in Markdown (400-600 words)
      - summary: 2-sentence summary
  INSTRUCTIONS
  payload: { research: }
)

article = wait_for_result(agent, write_task["id"], "writer")

# Step 3 — Publish
puts "\nStep 3: Publishing..."
sources_section = if research["sources"]&.any?
  "\n\n---\n**Sources:** #{research["sources"].join(", ")}"
else
  ""
end

publication = agent.publish(
  :article,
  title:   article["title"],
  body:    article["body"] + sources_section,
  summary: article["summary"]
)

puts "Published: https://#{agent.handle}.agentd.link/publications/#{publication["slug"]}"
puts "\nChain complete: #{RESEARCHER} → #{WRITER} → #{agent.handle}"
