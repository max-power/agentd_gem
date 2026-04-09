require "faraday"
require "json"

module Agentd
  # Runs an agentic loop: Ollama (or any OpenAI-compatible LLM) + agentd.link MCP tools.
  #
  # Usage:
  #   runner = Agentd::Runner.new(
  #     api_key:  "your-relay-api-key",
  #     model:    "gemma3:latest",         # any ollama model with tool support
  #     endpoint: "http://localhost:3000", # power relay
  #     ollama:   "http://localhost:11434" # ollama
  #   )
  #   runner.run("Summarise agentd.link and publish it as a note.")
  #
  class Runner
    MAX_ITERATIONS = 20

    def initialize(api_key:, model: "gemma3:latest",
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
        { role: "system",    content: @system_prompt },
        { role: "user",      content: task }
      ]

      log "Starting task: #{task}"
      log "Tools available: #{tools.map { |t| t.dig("function", "name") }.join(", ")}"

      MAX_ITERATIONS.times do |i|
        log "\n--- Turn #{i + 1} ---"
        response = chat(messages, tools)
        message  = response.dig("choices", 0, "message")
        messages << message

        tool_calls = message["tool_calls"]

        if tool_calls.nil? || tool_calls.empty?
          # Model is done — return final text response
          final = message["content"].to_s.strip
          log "\nFinal response: #{final}"
          return final
        end

        # Execute each tool call and feed results back
        tool_calls.each do |call|
          name      = call.dig("function", "name")
          args      = JSON.parse(call.dig("function", "arguments") || "{}")
          call_id   = call["id"]

          log "Tool call: #{name}(#{args.inspect})"
          result = execute_tool(name, args)
          log "Tool result: #{result.inspect}"

          messages << {
            role:         "tool",
            tool_call_id: call_id,
            content:      result.to_json
          }
        end
      end

      raise Error, "Exceeded #{MAX_ITERATIONS} iterations without a final response"
    end

    private

    def fetch_tools
      resp = @relay.instance_variable_get(:@connection)&.post("/mcp") rescue nil

      # Use the raw MCP tools/list call
      conn = Faraday.new(url: @relay.endpoint) do |f|
        f.request  :json
        f.headers["Authorization"] = "Bearer #{@api_key}"
        f.headers["Content-Type"]  = "application/json"
      end

      resp = conn.post("/mcp", {
        jsonrpc: "2.0", id: "tools-list", method: "tools/list", params: {}
      }.to_json)

      tools = JSON.parse(resp.body).dig("result", "tools") || []

      # Convert MCP inputSchema → OpenAI function format
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
        f.response :raise_error
        f.options.timeout      = 300
        f.options.open_timeout = 10
      end

      resp = conn.post("/v1/chat/completions", {
        model:    @model,
        messages:,
        tools:,
        stream:   false
      }.to_json)

      JSON.parse(resp.body)
    rescue Faraday::Error => e
      raise Error, "Ollama error: #{e.message}"
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
