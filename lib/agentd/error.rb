module Agentd
  class Error            < StandardError; end
  class AuthError        < Error; end
  class NotFoundError    < Error; end
  class ValidationError  < Error; end
  class McpError         < Error; end
end
