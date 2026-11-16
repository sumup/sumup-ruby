# frozen_string_literal: true

require_relative "test_helper"

class ModelsTest < Minitest::Test
  def test_nested_objects_arrays_and_unknown_fields_roundtrip
    payload = {"id" => "checkout", "transactions" => [{"id" => "tx", "status" => "FUTURE_STATUS", "new" => true}], "extra" => {"future" => [false, nil]}}
    checkout = SumUp::Types::Checkout.new(payload)
    assert_kind_of SumUp::Model, checkout.transactions.first
    assert_equal "FUTURE_STATUS", checkout.transactions.first.status
    assert_equal payload, checkout.to_h
    assert_equal payload, JSON.parse(checkout.to_json)
  end

  def test_missing_values_differ_from_null
    model = SumUp::Types::CheckoutUpdateRequest.new(valid_until: nil)
    assert model.key?(:valid_until)
    refute model.key?(:amount)
    assert_nil model.amount
    assert_nil model.valid_until
    assert_equal({"valid_until" => nil}, model.to_h)
  end

  def test_allof_inheritance_preserves_fields_from_every_parent
    transaction = SumUp::Types::TransactionFull.new(id: "id", merchant_code: "M123", entry_mode: "CONTACTLESS", foreign_transaction_id: "foreign")
    assert_equal "id", transaction.id
    assert_equal "CONTACTLESS", transaction.entry_mode
    assert_equal "foreign", transaction.foreign_transaction_id
    assert_equal "M123", transaction.merchant_code
  end

  def test_open_enum_constants_remain_strings
    assert_equal "EUR", SumUp::Types::Currency::EUR
    assert SumUp::Types::Currency::EUR.frozen?
    assert_equal "FUTURE", SumUp::Types::Checkout.new(status: "FUTURE").status
  end

  def test_maps_and_date_arguments_serialize_without_losing_false
    result = SumUp::Types.encode({enabled: false, date: Date.new(2026, 1, 2), time: Time.utc(2026, 1, 2)})
    assert_equal false, result.fetch("enabled")
    assert_equal "2026-01-02", result.fetch("date")
    assert_equal "2026-01-02T00:00:00Z", result.fetch("time")
  end

  def test_reserved_ruby_method_names_have_safe_field_accessors
    model = SumUp::Types::CheckoutAcceptedNextStep.new("method" => "POST")
    assert_equal "POST", model.method_value
    assert_equal "POST", model["method"]
    assert_equal({"method" => "POST"}, model.to_h)
  end
end
