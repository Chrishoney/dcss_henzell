require 'sql/summary_field'
require 'query/grammar'

module Sql
  class SummaryFieldList
    include Query::Grammar

    FIELD_OR_FUNCTION = %r/#{FIELD}|#{FUNCTION_CALL}/

    attr_reader :fields

    def multiple_field_group?
      @fields.size > 1
    end

    def self.summary_field?(clause)
      field_regex = %r/[+-]?#{FIELD_OR_FUNCTION}%?/
      if clause =~ /^-?s(?:\s*=(\s*#{field_regex}(?:\s*,\s*#{field_regex})*))$/
        return $1 || 'name'
      end
      return nil
    end

    def initialize(s_clauses)
      field_list = SummaryFieldList.summary_field?(s_clauses)
      unless field_list
        raise StandardError.new("Malformed summary clause: #{s_clauses}")
      end

      fields = field_list.split(",").map { |field| field.strip }
      @fields = fields.map { |f| SummaryField.new(f) }

      seen_fields = Set.new
      for field in @fields
        if seen_fields.include?(field.field)
          raise StandardError.new("Repeated field #{field.field} " +
            "in summary list #{s_clauses}")
        end
      end
    end

    def default_sort_expr
      sort_field = fields[0]
      sort_order = sort_field.order
      sort_condition = 'n'
      # Dates get special treatment: their default order is chronological
      if sort_field.date?
        sort_order = sort_order == '+' ? '-' : '+'
        sort_condition = '.'
      end
      "o=#{sort_order}#{sort_condition}"
    end
  end
end
