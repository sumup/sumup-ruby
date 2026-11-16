# frozen_string_literal: true

module SumUp
  module Resources
    class Sales
      # Lazily enumerates full sales, preserving the API's opaque pagination token.
      def each(**arguments, &block)
        return enum_for(__method__, **arguments) unless block
        each_token_page(:list, arguments) { |page| page.items.each(&block) }
      end

      def search_each(**arguments, &block)
        return enum_for(__method__, **arguments) unless block
        each_token_page(:search, arguments) { |page| page.items.each(&block) }
      end

      private

      def each_token_page(method, arguments)
        arguments = arguments.dup
        if method == :search
          payload = request_body(arguments.delete(:body) { UNSET }, arguments.except(:merchant_code, :options))
          payload = payload.to_h if payload.is_a?(Model)
          payload = {} if payload.equal?(UNSET)
          raise ArgumentError, "search body must be a Hash or Model" unless payload.is_a?(Hash)
          arguments = arguments.slice(:merchant_code, :options)
          arguments[:body] = payload.transform_keys(&:to_s)
        end
        seen = Set.new
        loop do
          page = public_send(method, **arguments)
          yield page
          token = page.pagination_token
          break if token.nil? || token.empty?
          raise InvalidResponseError, "API repeated a pagination token" unless seen.add?(token)
          if method == :search
            arguments[:body] = arguments[:body].merge("pagination_token" => token)
          else
            arguments[:pagination_token] = token
          end
        end
      end
    end

    class Transactions
      # Uses the API's next-page query string on the same history endpoint.
      def each(**arguments, &block)
        return enum_for(__method__, **arguments) unless block
        page = list(**arguments)
        seen = Set.new
        loop do
          Array(page.items).each(&block)
          link = Array(page.links).find { |item| item.rel == "next" }
          break if link&.href.nil? || link.href.empty?
          raise InvalidResponseError, "API repeated a pagination link" unless seen.add?(link.href)
          path = "/v2.1/merchants/#{path_segment(arguments.fetch(:merchant_code))}/transactions/history"
          # This API returns a query string rather than an absolute URL.
          query = link.href.delete_prefix("?")
          if query.include?("#") || query.start_with?("/", "http:", "https:")
            raise InvalidResponseError, "invalid transaction pagination query"
          end
          page = @client.request(method: "GET", path: "#{path}?#{query}", options: arguments[:options],
            response_type: [:model, "ListTransactionsV21Response"])
        end
      end
    end

    module OffsetPagination
      def each(**arguments, &block)
        return enum_for(__method__, **arguments) unless block
        arguments = arguments.dup
        arguments[:offset] ||= 0
        loop do
          page = list(**arguments)
          items = Array(page.items)
          break if items.empty?
          items.each(&block)
          arguments[:offset] += items.size
          break if page.total_count && arguments[:offset] >= page.total_count
        end
      end
    end

    class Members
      include OffsetPagination
    end

    class Memberships
      include OffsetPagination
    end
  end
end
