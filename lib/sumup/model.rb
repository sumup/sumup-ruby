# frozen_string_literal: true

require "json"
require "date"
require "time"

module SumUp
  # Base for generated API objects. Unknown fields and enum values are retained.
  # Use #key? to distinguish a missing value from an explicit JSON null.
  class Model
    class << self
      def fields
        @fields ||= {}
      end

      def field(name, type, wire: name.to_s, required: false)
        fields[name] = {wire: wire, type: type, required: required}.freeze
        define_method(name) { @attributes[wire] }
      end

      def from_hash(value)
        new(value)
      end
    end

    def initialize(attributes = {}, **keywords)
      raise ArgumentError, "expected a Hash" unless attributes.is_a?(Hash)
      @attributes = {}
      attributes.merge(keywords).each do |key, value|
        field = self.class.fields[key.to_sym]
        wire = field ? field[:wire] : key.to_s
        field ||= self.class.fields.values.find { |candidate| candidate[:wire] == wire }
        @attributes[wire] = field ? Types.decode(value, field[:type]) : value
      end
    end

    def [](key)
      field = self.class.fields[key.to_sym]
      @attributes[field ? field[:wire] : key.to_s]
    end

    def key?(key)
      field = self.class.fields[key.to_sym]
      @attributes.key?(field ? field[:wire] : key.to_s)
    end

    def to_h
      @attributes.transform_values { |value| Types.encode(value) }
    end

    def to_json(*arguments)
      JSON.generate(to_h, *arguments)
    end

    # Models can contain payment or personal data; inspection reports field names only.
    def inspect
      "#<#{self.class} fields=#{@attributes.keys.inspect}>"
    end

    def ==(other)
      other.instance_of?(self.class) && to_h == other.to_h
    end
  end

  module Types
    class << self
      def decode(value, descriptor)
        return nil if value.nil?
        return value unless descriptor.is_a?(Array)

        kind, argument = descriptor
        case kind
        when :model
          value.is_a?(Hash) ? const_get(argument, false).from_hash(value) : value
        when :array
          value.is_a?(Array) ? value.map { |item| decode(item, argument) } : value
        when :map
          value.is_a?(Hash) ? value.transform_values { |item| decode(item, argument) } : value
        when :union
          candidate = argument.max_by { |type| match_score(value, type) }
          candidate ? decode(value, candidate) : value
        else
          value
        end
      end

      def encode(value)
        case value
        when Model then value.to_h
        when Hash then value.to_h { |key, item| [key.to_s, encode(item)] }
        when Array then value.map { |item| encode(item) }
        when Time, DateTime then value.iso8601
        when Date then value.iso8601
        else value
        end
      end

      private

      def match_score(value, descriptor)
        return 0 unless descriptor.is_a?(Array) && descriptor.first == :model && value.is_a?(Hash)
        fields = const_get(descriptor.last, false).fields.values
        required = fields.select { |field| field[:required] }
        return -1 unless required.all? { |field| value.key?(field[:wire]) || value.key?(field[:wire].to_sym) }
        fields.count { |field| value.key?(field[:wire]) || value.key?(field[:wire].to_sym) }
      end
    end
  end
end
