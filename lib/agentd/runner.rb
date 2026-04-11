require "faraday"
require "json"

module Agentd
  # Runs an agentic loop: Ollama (native /api/chat) + agentd.link MCP tools.
  #
  # Usage:
  #   runner = Agentd::Runner.new(
  #     api_key:  "your-relay-api-key",
  #     model:    "gemma3:1b",            # any ollama model with tool support
  #     endpoint: "http://localhost:3000", # agentd
  #     ollama:   "http://localhost:11434" # ollama
  #   )
  #   runner.run("Summarise agentd.link and publish it as a note.")
  #
  class Runner
    MAX_ITERATIONS = 20

    def initialize(api_key:, model: "gemma3:1b",
                   endpoint: Agentd.endpoint,
                   ollama: "http://localhost:11434",
                   system_prompt: nil,
                   verbose: false)
      @api_key       = api_key
      @model         = model
      @relay         = Client.new(api_key:, endpoint:)
      @ollama_url    = ollama.chomp("/")
      @system_prompt = system_prompt || default_system_prompt
      @verbose       = verbose
    end

    def run(task)
      tools    = fetch_tools
      messages = [
        { role: "system", content: @system_prompt },
        { role: "user",   content: task }
      ]

      log "Starting task: #{task}"
      log "Tools available: #{tools.map { |t| t.dig("function", "name") }.join(", ")}"

      MAX_ITERATIONS.times do |i|
        log "\n--- Turn #{i + 1} ---"
        response  = chat(messages, tools)
        message   = response["message"]
        messages << { role: message["role"], content: message["content"] }

        tool_calls = message["tool_calls"]

        if tool_calls.nil? || tool_calls.empty?
          final = message["content"].to_s.strip
          log "\nFinal response: #{final}"
          return final
        end

        tool_calls.each do |call|
          name   = call.dig("function", "name")
          # Native Ollama returns arguments as a Hash, not a JSON string
          args   = call.dig("function", "arguments") || {}
          args   = JSON.parse(args) if args.is_a?(String)

          log "Tool call: #{name}(#{args.inspect})"
          result = execute_tool(name, args)
          log "Tool result: #{result.inspect}"

          messages << { role: "tool", content: result.to_json }
        end
      end

      raise Error, "Exceeded #{MAX_ITERATIONS} iterations without a final response"
    end

    private

    def fetch_tools
      conn = Faraday.new(url: @relay.endpoint) do |f|
        f.request  :json
        f.headers["Authorization"] = "Bearer #{@api_key}"
        f.headers["Content-Type"]  = "application/json"
      end

      resp  = conn.post("/mcp", {
        jsonrpc: "2.0", id: "tools-list", method: "tools/list", params: {}
      }.to_json)

      tools = JSON.parse(resp.body).dig("result", "tools") || []

      # Convert MCP inputSchema → Ollama function format
      tools.map do |t|
        {
          type:     "function",
          function: {
            name:        t["name"],
            description: t["description"],
            parameters:  t["inputSchema"]
          }
        }
      end
    end

    def execute_tool(name, args)
      @relay.tool(name, **args.transform_keys(&:to_sym))
    rescue => e
      { error: e.message }
    end

    def chat(messages, tools)
      conn = Faraday.new(url: @ollama_url) do |f|
        f.request  :json
        f.options.timeout      = 300
        f.options.open_timeout = 10
      end

      resp = conn.post("/api/chat", {
        model:    @model,
        messages:,
        tools:,
        stream:   false
      }.to_json)

      raise Error, "Ollama error: #{resp.status} #{resp.body.to_s[0, 200]}" unless resp.success?

      JSON.parse(resp.body)
    rescue Faraday::Error => e
      raise Error, "Ollama connection error: #{e.message}"
    end

    def default_system_prompt
      identity = @relay.tool("get_identity") rescue {}
      <<~PROMPT
        You are #{identity["handle"] || "an AI agent"} running on agentd.link.
        Your DID is #{identity["did"]}.
        Your email is #{identity["email"]}.

        You have access to a set of tools via the agentd.link MCP server. Use them to
        complete the task. When you are done, respond with a plain text summary of what
        you did. Do not make up tool results — only report what the tools actually return.
      PROMPT
    end

    def log(msg)
      $stderr.puts msg if @verbose
    end
  end
end
