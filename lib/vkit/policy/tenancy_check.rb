# frozen_string_literal: true

module Vkit
  module Policy
    # Checks the tenant columns in datasets/registry.yaml. A dataset with
    # `tenant_column: <field>` is confined to the requester's tenant on every
    # query. The risk is a tenant table nobody marked, so a dataset that has
    # another dataset's tenant column must either be marked too, or say
    # `tenant_column: false` to declare every tenant may read all of it.
    class TenancyCheck
      def self.call(raw_registry)
        new(raw_registry || {}).call
      end

      def initialize(raw_registry)
        @datasets = raw_registry.to_h { |name, data| [name.to_s, data || {}] }
      end

      def call
        @datasets.flat_map { |name, data| problems(name, data) }
      end

      private

      def problems(name, data)
        column = data["tenant_column"]
        fields = (data["fields"] || {}).keys.map(&:to_s)

        case column
        when false then []
        when nil then unmarked(name, fields)
        when String
          return [] if fields.include?(column)

          ["#{name}: tenant_column #{column} isn't one of its fields, so no query on it could be confined to a tenant."]
        else
          ["#{name}: tenant_column must be a field name, or false for a table every tenant may read."]
        end
      end

      def unmarked(name, fields)
        (fields & tenant_columns).map do |column|
          owners = @datasets.select { |_, d| d["tenant_column"] == column }.keys.join(", ")
          "#{name} has #{column}, the tenant column of #{owners}, but no tenant_column. Add " \
            "`tenant_column: #{column}` to confine it to one tenant, or `tenant_column: false` if every tenant may read all of it."
        end
      end

      def tenant_columns
        @tenant_columns ||= @datasets.values.map { |d| d["tenant_column"] }.grep(String).uniq
      end
    end
  end
end
