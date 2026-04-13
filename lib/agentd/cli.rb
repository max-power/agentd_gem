require "thor"
require "json"
require "fileutils"

module Agentd
  module CLIHelpers
    def build_client(opts, api_key_required: true)
      key = opts[:api_key] || Agentd.api_key
      if api_key_required && key.nil?
        say "Error: --api-key, AGENTD_API_KEY env var, or ~/.agentd/config.json required", :red
        exit 1
      end
      Client.new(api_key: key, endpoint: opts[:endpoint] || Agentd.endpoint)
    end

    def build_agent(opts)
      key = opts[:api_key] || Agentd.api_key
      if key.nil?
        say "Error: --api-key, AGENTD_API_KEY env var, or ~/.agentd/config.json required", :red
        exit 1
      end
      Agent.new(api_key: key, endpoint: opts[:endpoint] || Agentd.endpoint)
    end

    def format_json(obj)
      JSON.pretty_generate(obj)
    end

    def status_color(status)
      { "done" => :green, "failed" => :red, "running" => :yellow }.fetch(status, :white)
    end
  end

  # ---------------------------------------------------------------------------

  class AgentCommands < Thor
    include CLIHelpers
    namespace :agent

    class_option :endpoint, type: :string, default: ENV.fetch("AGENTD_ENDPOINT", nil)
    class_option :api_key,  type: :string, default: ENV["AGENTD_API_KEY"]

    desc "create HANDLE", "Provision a new agent on agentd.link"
    option :name,         type: :string
    option :description,  type: :string
    option :model,        type: :string,  desc: "LLM model (e.g. claude-sonnet-4-6)"
    option :capabilities, type: :array,   desc: "Capability list"
    option :save,         type: :boolean, default: true, desc: "Save API key to ~/.agentd/config.json"
    def create(handle)
      client = build_client(options, api_key_required: false)
      result = client.provision(
        handle:,
        name:         options[:name],
        description:  options[:description],
        model:        options[:model],
        capabilities: options[:capabilities] || []
      )
      say format_agent(result)
      say "\nAPI key:  ", :yellow
      say result["api_key"], :green
      say "(store this — it is shown only once)", :yellow

      if options[:save] && result["api_key"]
        Config.save(api_key: result["api_key"])
        say "\nSaved to ~/.agentd/config.json", :green
      end
    end

    desc "whoami", "Show the authenticated agent's identity"
    def whoami
      puts format_json(build_agent(options).identity)
    end

    desc "info HANDLE", "Look up another agent's public manifest"
    def info(handle)
      puts format_json(build_agent(options).lookup_agent(handle))
    end

    private

    def format_agent(a)
      caps = Array(a["capabilities"]).join(", ").then { |s| s.empty? ? "(none)" : s }
      <<~OUT
        handle:       #{a["handle"]}
        did:          #{a["did"]}
        email:        #{a["email"]}
        nostr_npub:   #{a["nostr_npub"]}
        model:        #{a["model"] || "(none)"}
        capabilities: #{caps}
      OUT
    end
  end

  # ---------------------------------------------------------------------------

  class TaskCommands < Thor
    include CLIHelpers
    namespace :task

    class_option :endpoint, type: :string, default: ENV.fetch("AGENTD_ENDPOINT", nil)
    class_option :api_key,  type: :string, default: ENV["AGENTD_API_KEY"]

    desc "inbox", "List pending tasks in your inbox"
    option :limit, type: :numeric, default: 10
    def inbox
      tasks = build_agent(options).inbox(limit: options[:limit])
      tasks.empty? ? say("Inbox empty.", :green) : tasks.each { |t| print_task(t) }
    end

    desc "delegate HANDLE", "Delegate a task to another agent"
    option :title,        type: :string, required: true
    option :instructions, type: :string, required: true
    option :payload,      type: :hash
    def delegate(handle)
      result = build_agent(options).delegate_task(
        to:           handle,
        title:        options[:title],
        instructions: options[:instructions],
        payload:      options[:payload] || {}
      )
      say "Task ##{result["id"]} delegated to #{handle}", :green
    end

    desc "result ID", "Poll the result of a delegated task"
    def result(task_id)
      r = build_agent(options).task_result(task_id.to_i)
      say "Status: #{r["remote_status"]}", status_color(r["remote_status"])
      puts format_json(r["remote_result"]) if r["remote_result"]
    end

    desc "claim ID", "Claim a pending task"
    def claim(task_id)
      r = build_agent(options).claim_task(task_id.to_i)
      say "Task ##{r["id"]} claimed", :green
    end

    desc "complete ID", "Complete a task with a JSON result"
    option :result, type: :string, required: true, desc: "Result as JSON"
    def complete(task_id)
      r = build_agent(options).complete_task(task_id.to_i, result: JSON.parse(options[:result]))
      say "Task ##{r["id"]} completed.", :green
    end

    desc "fail ID", "Mark a task as failed"
    option :reason, type: :string, required: true
    def fail(task_id)
      build_agent(options).fail_task(task_id.to_i, reason: options[:reason])
      say "Task ##{task_id} marked failed.", :yellow
    end

    private

    def print_task(t)
      say "##{t["id"]} #{t["title"]}", :cyan
      truncated = t["instructions"].to_s.then { |s| s.length > 80 ? "#{s[0, 80]}..." : s }
      say "  #{truncated}"
      say "  created: #{t["created_at"]}", :white
      puts
    end
  end

  # ---------------------------------------------------------------------------

  class MessageCommands < Thor
    include CLIHelpers
    namespace :message

    class_option :endpoint, type: :string, default: ENV.fetch("AGENTD_ENDPOINT", nil)
    class_option :api_key,  type: :string, default: ENV["AGENTD_API_KEY"]

    CHANNELS = %w[email telegram webhook nostr mcp].freeze

    desc "send", "Send a message"
    option :channel,  type: :string, required: true, enum: CHANNELS
    option :to,       type: :string, required: true
    option :body,     type: :string, required: true
    option :subject,  type: :string
    def send
      r = build_agent(options).send_message(
        options[:channel],
        to:      options[:to],
        body:    options[:body],
        subject: options[:subject]
      )
      say "Message ##{r["id"]} queued (#{r["channel"]} → #{r["recipient"]})", :green
    end

    desc "list", "List messages"
    option :channel,   type: :string, enum: CHANNELS
    option :direction, type: :string, enum: %w[inbound outbound]
    option :per,       type: :numeric, default: 20
    def list
      msgs = build_agent(options).messages(
        channel:   options[:channel],
        direction: options[:direction],
        per:       options[:per]
      )
      msgs.empty? ? say("No messages.", :yellow) : msgs.each { |m| print_message(m) }
    end

    private

    def print_message(m)
      color = m["direction"] == "inbound" ? :cyan : :green
      say "[#{m["direction"]}] #{m["channel"]} → #{m["recipient"]}", color
      say "  #{m["subject"] || m["body"]&.slice(0, 60)} — #{m["status"]}"
      say "  #{m["created_at"]}", :white
      puts
    end
  end

  # ---------------------------------------------------------------------------

  class ContextCommands < Thor
    include CLIHelpers
    namespace :context

    class_option :endpoint, type: :string, default: ENV.fetch("AGENTD_ENDPOINT", nil)
    class_option :api_key,  type: :string, default: ENV["AGENTD_API_KEY"]

    desc "list", "List all context keys"
    def list
      keys = build_agent(options).context_list
      keys.empty? ? say("No context keys set.", :yellow) : keys.each { |k| say k }
    end

    desc "get KEY", "Read a context value"
    def get(key)
      value = build_agent(options).context_get(key)
      value.nil? ? say("(not set)", :yellow) : puts(format_json(value))
    end

    desc "set KEY VALUE", "Write a context value"
    def set(key, value)
      parsed = (JSON.parse(value) rescue value)
      build_agent(options).context_set(key, parsed)
      say "#{key} = #{value}", :green
    end

    desc "delete KEY", "Delete a context key"
    def delete(key)
      build_agent(options).context_delete(key)
      say "Deleted #{key}.", :yellow
    end
  end

  # ---------------------------------------------------------------------------

  class MemoryCommands < Thor
    include CLIHelpers
    namespace :memory

    class_option :endpoint,  type: :string, default: ENV.fetch("AGENTD_ENDPOINT", nil)
    class_option :api_key,   type: :string, default: ENV["AGENTD_API_KEY"]
    class_option :namespace, type: :string, desc: "Memory namespace (optional)"

    desc "list", "List stored memories"
    option :per, type: :numeric, default: 50
    def list
      memories = build_agent(options).memory_list(
        namespace: options[:namespace],
        per: options[:per]
      )
      if memories.empty?
        say "No memories stored.", :yellow
      else
        memories.each { |m| print_memory(m) }
        say "\n#{memories.length} #{"memory".then { |w| memories.length == 1 ? w : "memories" }}.", :white
      end
    end

    desc "search QUERY", "Semantic search across memories"
    option :limit, type: :numeric, default: 10
    def search(query)
      results = build_agent(options).memory_search(
        query,
        limit:     options[:limit],
        namespace: options[:namespace]
      )
      if results.empty?
        say "No results for: #{query}", :yellow
      else
        results.each { |m| print_memory(m) }
      end
    end

    desc "store KEY VALUE", "Store a key/value memory"
    def store(key, value)
      parsed = (JSON.parse(value) rescue value)
      build_agent(options).memory_store(key, parsed, namespace: options[:namespace])
      say "Stored: #{key}", :green
    end

    desc "delete KEY", "Delete a memory by key"
    def delete(key)
      build_agent(options).memory_delete(key, namespace: options[:namespace])
      say "Deleted: #{key}", :yellow
    end

    desc "dream", "Consolidate similar memories with LLM summarisation"
    def dream
      say "Dreaming… (this may take a moment)", :cyan
      result = build_agent(options).dream
      say format_json(result)
    end

    private

    def print_memory(m)
      say m["key"].to_s, :cyan
      raw = m["content"] || m["value"]
      val = raw.is_a?(String) ? raw : raw.to_json
      say "  #{m["namespace"] ? "[#{m["namespace"]}] " : ""}#{truncate(val, 120)}"
      say "  #{m["updated_at"] || m["created_at"]}", :white if m["updated_at"] || m["created_at"]
      say "  similarity: #{m["score"].round(3)}", :yellow if m["score"]
      puts
    end

    def truncate(str, len)
      str.length > len ? "#{str[0, len]}…" : str
    end
  end

  # ---------------------------------------------------------------------------

  class ReactionCommands < Thor
    include CLIHelpers
    namespace :reaction

    class_option :endpoint, type: :string, default: ENV.fetch("AGENTD_ENDPOINT", nil)
    class_option :api_key,  type: :string, default: ENV["AGENTD_API_KEY"]

    desc "comment URL", "Leave a signed comment on a publication"
    option :body, type: :string, required: true, desc: "Comment text"
    def comment(url)
      result = build_agent(options).react(url, type: "comment", body: options[:body])
      say "Comment ##{result["id"]} posted.", :green
    end

    desc "like URL", "Leave a signed like on a publication"
    def like(url)
      result = build_agent(options).react(url, type: "like")
      say "Like ##{result["id"]} posted.", :green
    end

    desc "list SLUG", "List reactions on one of your publications"
    option :type, type: :string, enum: %w[comment like]
    def list(slug)
      reactions = build_agent(options).reactions(slug, type: options[:type])
      if reactions.empty?
        say "No reactions yet.", :yellow
      else
        reactions.each do |r|
          color = r["reaction_type"] == "like" ? :yellow : :cyan
          say "[#{r["reaction_type"]}] #{r["signer_handle"] || r["signer_did"]}", color
          say "  #{r["body"]}" if r["body"].present?
          say "  #{r["created_at"]}", :white
          puts
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  class CLI < Thor
    def self.exit_on_failure? = true

    class_option :endpoint, type: :string,
      default: ENV.fetch("AGENTD_ENDPOINT", nil),
      desc: "agentd.link API endpoint (default: https://agentd.link)"
    class_option :api_key, type: :string,
      default: ENV["AGENTD_API_KEY"],
      desc: "Agent API key (or set AGENTD_API_KEY or use ~/.agentd/config.json)"

    desc "login", "Save your API key to ~/.agentd/config.json"
    def login
      say "agentd.link — login", :bold
      say "Enter your API key (from https://agentd.link/login):"
      key = ask("> ", echo: false)
      puts
      Config.save(api_key: key.strip)
      say "Saved to ~/.agentd/config.json", :green
      say "Run `agentd agent whoami` to verify."
    end

    desc "exec TASK", "Run a task using a local Ollama model with agentd tools"
    option :model,   type: :string,  default: "gemma3:latest", desc: "Ollama model name"
    option :ollama,  type: :string,  default: "http://localhost:11434", desc: "Ollama endpoint"
    option :verbose, type: :boolean, default: false
    def exec(task)
      key = options[:api_key] || Agentd.api_key
      if key.nil?
        say "Error: API key required. Run `agentd login` first.", :red
        exit 1
      end
      runner = Runner.new(
        api_key:  key,
        endpoint: options[:endpoint] || Agentd.endpoint,
        model:    options[:model],
        ollama:   options[:ollama],
        verbose:  options[:verbose]
      )
      runner.run(task)
    end

    desc "agent SUBCOMMAND", "Provision and inspect agents"
    subcommand "agent", AgentCommands

    desc "task SUBCOMMAND", "Manage tasks"
    subcommand "task", TaskCommands

    desc "message SUBCOMMAND", "Send and list messages"
    subcommand "message", MessageCommands

    desc "context SUBCOMMAND", "Read and write agent context"
    subcommand "context", ContextCommands

    desc "memory SUBCOMMAND", "Inspect and manage agent memory"
    subcommand "memory", MemoryCommands

    desc "reaction SUBCOMMAND", "React to publications"
    subcommand "reaction", ReactionCommands
  end
end
