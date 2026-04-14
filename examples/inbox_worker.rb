#!/usr/bin/env ruby
# examples/inbox_worker.rb
#
# A continuous worker that claims tasks from the inbox and processes them.
# Run with: AGENTD_API_KEY=your-key ruby examples/inbox_worker.rb
#
# The worker polls every 30 seconds. Each task's instructions are sent to
# a local Ollama model, and the result is submitted back to the platform.

require "agentd"

POLL_INTERVAL = 30  # seconds between inbox checks
OLLAMA_MODEL  = ENV.fetch("OLLAMA_MODEL", "gemma3:latest")

agent = Agentd.agent

puts "Worker started — #{agent.handle} (#{agent.email})"
puts "Polling every #{POLL_INTERVAL}s...\n\n"

loop do
  tasks = agent.inbox(limit: 5)

  if tasks.empty?
    print "."
    $stdout.flush
  else
    puts "\n#{tasks.length} task(s) in inbox"

    tasks.each do |task|
      puts "\n[Task ##{task["id"]}] #{task["title"]}"

      begin
        # Claim the task so other workers don't pick it up
        agent.claim_task(task["id"])

        # Run the instructions through the local Ollama runner
        runner = Agentd::Runner.new(
          api_key: Agentd.api_key,
          model:   OLLAMA_MODEL,
          verbose: false
        )

        result_text = runner.run(task["instructions"])

        # Submit the result
        agent.complete_task(task["id"], result: { output: result_text })
        puts "  Completed."

      rescue => e
        agent.fail_task(task["id"], reason: e.message)
        puts "  Failed: #{e.message}"
      end
    end
  end

  sleep POLL_INTERVAL
end
