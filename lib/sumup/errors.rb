# frozen_string_literal: true

module SumUp
  class Error < StandardError; end

  class APIConnectionError < Error; end

  class APITimeoutError < APIConnectionError; end

  class InvalidResponseError < Error; end

  class APIError < Error
    attr_reader :status, :body, :headers, :request_id, :problem

    def initialize(status:, body:, headers: {})
      @status = status
      @body = body
      @headers = headers.freeze
      @request_id = headers["x-request-id"] || headers["x-correlation-id"]
      @problem = Types::Problem.new(body) if body.is_a?(Hash) && body["type"].is_a?(String)
      # Error payloads may contain sensitive data. Inspect #body explicitly when needed.
      super("SumUp API returned HTTP #{status}#{" (request #{@request_id})" if @request_id}")
    end

    def inspect
      "#<#{self.class} status=#{status}>"
    end
  end

  class APIStatusError < APIError; end
  class BadRequestError < APIStatusError; end
  class AuthenticationError < APIStatusError; end
  class PermissionDeniedError < APIStatusError; end
  class NotFoundError < APIStatusError; end
  class ConflictError < APIStatusError; end
  class UnprocessableEntityError < APIStatusError; end
  class RateLimitError < APIStatusError; end
  class InternalServerError < APIStatusError; end

  STATUS_ERRORS = {
    400 => BadRequestError, 401 => AuthenticationError,
    403 => PermissionDeniedError, 404 => NotFoundError,
    409 => ConflictError, 422 => UnprocessableEntityError, 429 => RateLimitError
  }.freeze
end
