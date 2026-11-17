# frozen_string_literal: true

require_relative "test_helper"

class PaginationTest < Minitest::Test
  def test_sales_enumerator_is_lazy_and_preserves_opaque_tokens
    client = build_client(json_response({"items" => [{"id" => "one"}], "pagination_token" => "next/+ token"}), json_response({"items" => [{"id" => "two"}]}))
    enumeration = client.sales.each(merchant_code: "M123", pagination_limit: 5)
    assert_empty @transport.requests
    assert_equal %w[one two], enumeration.map(&:id)
    assert_equal [["pagination_token", "next/+ token"], ["pagination_limit", "5"]], URI.decode_www_form(@transport.requests.last.uri.query)
  end

  def test_search_pagination_keeps_filters_and_does_not_mutate_input
    client = build_client(json_response({"items" => [], "pagination_token" => "next"}), json_response({"items" => [{"id" => "two"}]}))
    body = {start_date: "2026-01-01", payment_status: ["SUCCESSFUL"]}.freeze
    assert_equal ["two"], client.sales.search_each(merchant_code: "M123", body: body).map(&:id)
    assert_equal({"start_date" => "2026-01-01", "payment_status" => ["SUCCESSFUL"], "pagination_token" => "next"}, JSON.parse(@transport.requests.last.body))
    refute body.key?(:pagination_token)
  end

  def test_search_pagination_accepts_a_request_model
    client = build_client(json_response({"items" => []}))
    body = SumUp::Types::SaleSearchRequest.new(start_date: "2026-01-01")
    assert_empty client.sales.search_each(merchant_code: "M123", body: body).to_a
    assert_equal({"start_date" => "2026-01-01"}, JSON.parse(@transport.requests.last.body))
  end

  def test_search_pagination_rejects_body_keywords
    client = build_client
    assert_raises(ArgumentError) { client.sales.search_each(merchant_code: "M123", start_date: "2026-01-01").to_a }
    assert_empty @transport.requests
  end

  def test_repeated_tokens_do_not_loop_forever
    response = json_response({"items" => [], "pagination_token" => "same"})
    client = build_client(response, response)
    assert_raises(SumUp::InvalidResponseError) { client.sales.each(merchant_code: "M123").to_a }
    assert_equal 2, @transport.requests.size
  end

  def test_transaction_history_uses_returned_query_string_on_history_path
    client = build_client(json_response({"items" => [{"id" => "one"}], "links" => [{"rel" => "next", "href" => "limit=2&oldest_ref=next%2Fref&order=ascending"}]}), json_response({"items" => [{"id" => "two"}], "links" => []}))
    assert_equal %w[one two], client.transactions.each(merchant_code: "M123", options: {api_key: "override"}).map(&:id)
    assert_equal "/v2.1/merchants/M123/transactions/history", @transport.requests.last.uri.path
    assert_equal [["limit", "2"], ["oldest_ref", "next/ref"], ["order", "ascending"]], URI.decode_www_form(@transport.requests.last.uri.query)
    assert_equal "Bearer override", @transport.requests.last.headers.fetch("authorization")
  end

  def test_transaction_pagination_rejects_urls_and_cycles
    ["https://evil.example/a", "/another-path", "limit=1#fragment"].each do |href|
      client = build_client(json_response({"items" => [], "links" => [{"rel" => "next", "href" => href}]}))
      assert_raises(SumUp::InvalidResponseError) { client.transactions.each(merchant_code: "M123").to_a }
      assert_equal 1, @transport.requests.size
    end
    response = json_response({"items" => [], "links" => [{"rel" => "next", "href" => "limit=1"}]})
    client = build_client(response, response)
    assert_raises(SumUp::InvalidResponseError) { client.transactions.each(merchant_code: "M123").to_a }
  end

  def test_membership_pagination_increments_offset_and_obeys_total
    client = build_client(json_response({"items" => [{"id" => "one"}], "total_count" => 2}), json_response({"items" => [{"id" => "two"}], "total_count" => 2}))
    assert_equal %w[one two], client.memberships.each(limit: 1).map(&:id)
    assert_equal [["offset", "1"], ["limit", "1"]], URI.decode_www_form(@transport.requests.last.uri.query)
    assert_equal 2, @transport.requests.size
  end

  def test_member_pagination_stops_on_empty_page_without_total
    client = build_client(json_response({"items" => [{"id" => "one"}]}), json_response({"items" => []}))
    assert_equal ["one"], client.members.each(merchant_code: "M123").map(&:id)
    assert_equal 2, @transport.requests.size
  end
end
