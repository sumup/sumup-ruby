# frozen_string_literal: true

module SumUp
  class Resource
    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class}>"
    end

    private

    def path_segment(value)
      raise ArgumentError, "path parameters cannot be nil or empty" if value.nil? || value.to_s.empty?
      URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end

    def request_body(body, fields)
      unless body.equal?(UNSET)
        raise ArgumentError, "pass body or body keywords, not both" unless fields.empty?
        return body
      end
      fields.empty? ? UNSET : fields
    end

    def merge_header_options(options, parameters)
      options = RequestOptions.new(**options) if options.is_a?(Hash)
      options ||= RequestOptions.new
      headers = parameters.reject { |_, value| value.equal?(UNSET) }.merge(options.headers)
      RequestOptions.new(headers: headers, api_key: options.api_key, timeout: options.timeout,
        open_timeout: options.open_timeout, max_retries: options.max_retries)
    end
  end
end
