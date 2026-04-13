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

      debug "Starting task: #{task}"
      debug "Tools available: #{tools.map { |t| t.dig("function", "name") }.join(", ")}"

      MAX_ITERATIONS.times do |i|
        debug "\n--- Turn #{i + 1} ---"
        response = chat_stream(messages, tools)
        message  = response["message"]
        messages << { role: message["role"], content: message["content"] }

        tool_calls = message["tool_calls"]

        if tool_calls.nil? || tool_calls.empty?
          # Final response was already streamed to stdout — just add trailing newline
          $stdout.puts
          return message["content"].to_s.strip
        end

        tool_calls.each do |call|
          name = call.dig("function", "name")
          args = call.dig("function", "arguments") || {}
          args = JSON.parse(args) if args.is_a?(String)

          if @verbose
            $stderr.puts "  → #{name}(#{args.inspect})"
          else
            $stderr.print "  → #{name}... "
            $stderr.flush
          end

          result = execute_tool(name, args)

          if @verbose
            $stderr.puts "  ✓ #{result.inspect}"
          else
            $stderr.puts "✓"
          end

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

    # Streams tokens to stdout as Ollama generates them.
    # Tool calls are collected from the final done=true chunk.
    # Returns a message hash compatible with the non-streaming format.
    def chat_stream(messages, tools)
      buffer       = +""
      full_content = +""
      tool_calls   = nil
      final_role   = "assistant"
      streaming    = false

      conn = Faraday.new(url: @ollama_url) do |f|
        f.options.timeout      = 300
        f.options.open_timeout = 10
      end

      conn.post("/api/chat") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = {
          model:    @model,
          messages:,
          tools:,
          stream:   true
        }.to_json

        req.options.on_data = proc do |chunk, _bytes, env|
          raise Error, "Ollama error: #{env&.status}" if env&.status && env.status >= 400

          buffer << chunk

          while (line = buffer.slice!(/\A[^\n]*\n/))
            line.strip!
            next if line.empty?

            data = JSON.parse(line) rescue next

            token = data.dig("message", "content").to_s
            final_role = data.dig("message", "role") || final_role

            if token.length > 0
              unless streaming
                # First token — newline after any tool status lines
                streaming = true
              end
              $stdout.print token
              $stdout.flush
              full_content << token
            end

            if data["done"]
              tool_calls = data.dig("message", "tool_calls")
            end
          end
        end
      end

      {
        "message" => {
          "role"       => final_role,
          "content"    => full_content,
          "tool_calls" => tool_calls
        }
      }
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

    def debug(msg)
      $stderr.puts msg if @verbose
    end
  end
end
