require "faraday"
require "json"

module Agentd
  # Low-level HTTP client for the Power Relay platform API and MCP endpoint.
  class Client
    attr_reader :endpoint, :api_key

    def initialize(api_key:, endpoint: Agentd.endpoint)
      @api_key  = api_key
      @endpoint = endpoint.chomp("/")
    end

    # Provision a new agent. Returns agent attributes including api_key.
    def provision(handle:, name: nil, description: nil, model: nil,
                  capabilities: [], initial_context: {}, metadata: {})
      resp = connection.post("/agents") do |req|
        req.body = JSON.generate(agent: {
          handle:,
          name:,
          description:,
          model:,
          capabilities:,
          initial_context:,
          metadata:
        }.compact)
      end
      handle_response(resp)
    end

    # Call an MCP tool on behalf of the authenticated agent.
    def tool(name, **args)
      resp = connection.post("/mcp") do |req|
        req.body = JSON.generate(
          jsonrpc: "2.0",
          id:      SecureRandom.hex(4),
          method:  "tools/call",
          params:  { name:, arguments: args }
        )
      end
      result = handle_response(resp)
      raise McpError, result.dig("error", "message") if result["error"]
      JSON.parse(result.dig("result", "content", 0, "text"))
    end

    private

    def connection
      @connection ||= Faraday.new(url: endpoint) do |f|
        f.request  :json
        f.response :raise_error
        f.headers["Authorization"] = "Bearer #{api_key}" if api_key
        f.headers["Content-Type"]  = "application/json"
        f.headers["Accept"]        = "application/json"
      end
    end

    def handle_response(resp)
      body = JSON.parse(resp.body)
      case resp.status
      when 200, 201 then body
      when 401      then raise AuthError, body["error"] || "Unauthorized"
      when 404      then raise NotFoundError, body["error"] || "Not found"
      when 422      then raise ValidationError, Array(body["errors"]).join(", ")
      else               raise Error, "Unexpected status #{resp.status}: #{resp.body}"
      end
    rescue JSON::ParserError
      raise Error, "Invalid JSON response: #{resp.body}"
    end
  end
end
