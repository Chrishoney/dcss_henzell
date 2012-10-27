require 'sql/query_field_list'

module Query
  class ExtraFieldParser
    EXTRA_REG = %r/\bx\s*=\s*([+-]?\w+(?:\(\w+\))?(?:\s*,\s*\w+(?:\(\w+\))?)*)/

    def self.parse(query_string, context)
      arg_str = query_string.to_s
      extra = nil
      extra = $1 if arg_str =~ EXTRA_REG
      query_string.argument_string = arg_str.sub(EXTRA_REG, '') if extra
      Sql::QueryFieldList.new(extra, context)
    end
  end
end
