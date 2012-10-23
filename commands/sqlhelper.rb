#!/usr/bin/env ruby

if !ENV['HENZELL_SQL_QUERIES']
  raise Exception.new("sqlhelper: HENZELL_SQL_QUERIES is not set")
end

LG_CONFIG_FILE = 'commands/crawl-data.yml'
LG_SERVERS_FILE = 'servers.yml'

require 'dbi'
require 'set'
require 'yaml'

require 'helper'
require 'tourney'
require 'commands/sql_connection'
require 'commands/henzell_config'
require 'sql/field_predicate'
require 'sql/query_result'
require 'sql/version_number'
require 'sql/lg_query'

include Tourney
include HenzellConfig

CFG = YAML.load_file(LG_CONFIG_FILE)
LG_SERVER_CFG = YAML.load_file(LG_SERVERS_FILE)

# Don't use more than this much memory (bytes)
MAX_MEMORY_USED = 768 * 1024 * 1024
Process.setrlimit(Process::RLIMIT_AS, MAX_MEMORY_USED)

GAME_TYPE_DEFAULT = CFG['default-game-type']
GAME_SPRINT = 'sprint'
GAMES = CFG['game-type-prefixes'].keys
GAME_PREFIXES = CFG['game-type-prefixes']

OPERATORS = {
  '==' => '=', '!==' => '!=',
  '=' => '=', '!=' => '!=', '<' => '<', '>' => '>',
  '<=' => '<=', '>=' => '>=', '=~' => 'ILIKE', '!~' => 'NOT ILIKE',
  '~~' => '~*', '!~~' => '!~*'
}

FILTER_OPS = {
  '<'   => Proc.new { |a, b| a.to_f < b },
  '<='  => Proc.new { |a, b| a.to_f <= b },
  '>'   => Proc.new { |a, b| a.to_f > b },
  '>='  => Proc.new { |a, b| a.to_f >= b },
  '='   => Proc.new { |a, b| a.to_f == b },
  '!='  => Proc.new { |a, b| a.to_f != b }
}

FILTER_OPS_ORDERED = FILTER_OPS.keys.sort { |a,b| b.length <=> a.length }

FILTER_PATTERN =
  Regexp.new('^((?:(?:den|num|%)[.])?\S+?)(' +
             FILTER_OPS_ORDERED.map { |o| Regexp.quote(o) }.join('|') +
             ')(\S+)$')

# List of abbreviations for branches that have depths > 1. This includes
# fake branches such as the Ziggurat.
DEEP_BRANCHES = CFG['branches'].find_all { |x| x =~ /:/ }.map { |x| x.sub(':', '') }
BRANCHES = CFG['branches'].map { |x| x.sub(':', '') }

GODABBRS = CFG['god'].keys
GODMAP = CFG['god']

SOURCES = LG_SERVER_CFG['sources'].keys.sort

BRANCH_SET = Set.new(BRANCHES.map { |br| br.downcase })
DEEP_BRANCH_SET = Set.new(DEEP_BRANCHES.map { |br| br.downcase })

CLASS_EXPANSIONS = CFG['classes']
RACE_EXPANSIONS = CFG['species']

BOOL_FIELDS = CFG['boolean-fields']

[ CLASS_EXPANSIONS, RACE_EXPANSIONS ].each do |hash|
  hash.keys.each do |key|
    hash[key.downcase] = hash[key]
  end
end

OPEN_PAREN = '(('
CLOSE_PAREN = '))'

BOOLEAN_OR = '||'
BOOLEAN_OR_Q = Regexp.quote(BOOLEAN_OR)

COLUMN_ALIASES = CFG['column-aliases']

AGGREGATE_FUNC_TYPES = CFG['aggregate-function-types']

LOGFIELDS_DECORATED = CFG['logrecord-fields-with-type']
MILEFIELDS_DECORATED = CFG['milestone-fields-with-type']
FAKEFIELDS_DECORATED = CFG['fake-fields-with-type']

# Never fetch more than 5000 rows, kthx.
ROWFETCH_MAX = 5000
DBFILE = "#{ENV['HOME']}/logfile.db"
LOGFIELDS = { }
MILEFIELDS = { }
FAKEFIELDS = { }

MILE_TYPES = CFG['milestone-types']

SORTEDOPS = OPERATORS.keys.sort { |a,b| b.length <=> a.length }
OPMATCH = Regexp.new(SORTEDOPS.map { |o| Regexp.quote(o) }.join('|'))
ARGSPLITTER = Regexp.new('^-?([a-z.:_]+)\s*(' +
                         SORTEDOPS.map { |o| Regexp.quote(o) }.join("|") +
                         ')\s*(.*)$', Regexp::IGNORECASE)

DB_NICKS = { }

# Automatically limit search to a specific server, unless explicitly
# otherwise requested.
SERVER = ENV['CRAWL_SERVER'] || 'cao'

[ [ LOGFIELDS_DECORATED, LOGFIELDS ],
  [ FAKEFIELDS_DECORATED, FAKEFIELDS ],
  [ MILEFIELDS_DECORATED, MILEFIELDS ] ].each do |fdec,fdict|
  fdec.each do |lf|
    class << lf
      def name
        self.sub(/[ID*?]+$/, '')
      end

      def fix_date(v)
        sql2logdate(v)
      end

      def indexed?
        self =~ /\?/
      end

      def summarisable?
        self !~ /\*/
      end

      def value(v)
        (self =~ /I/) ? v.to_i :
        (self =~ /D/) ? fix_date(v) : v
      end
    end

    if lf =~ /([ID])[*?]*$/
      type = $1
    else
      type = 'S'
    end
    fdict[ lf.name ] = type
  end
end

LOG2SQL = CFG['sql-field-names']
(LOGFIELDS_DECORATED + MILEFIELDS_DECORATED).each do |x|
  LOG2SQL[x.name] = x.name unless LOG2SQL[x.name]
end

LOGFIELDS_SUMMARISABLE =
  Hash[ *(LOGFIELDS_DECORATED.find_all { |x| x.summarisable? }.map { |x|
    [x.name, true]
  }.flatten) ]

MILEFIELDS_SUMMARISABLE =
  Hash[ *(MILEFIELDS_DECORATED.find_all { |x| x.summarisable? }.map { |x|
    [x.name, true]
  }.flatten) ]

module GameContext
  @@game = GAME_TYPE_DEFAULT

  def self.with_game(game)
    begin
      old_game = @@game
      @@game = game
      yield
    ensure
      @@game = old_game
    end
  end

  def self.game
    @@game
  end
end

module LGField
  def self.canonicalise_field(field)
    field = field.strip.downcase
    field = COLUMN_ALIASES[field] || field
    raise "Unknown selector #{field}" unless QueryContext.context.field?(field)
    field
  end
end

class QueryContext
  @@global_context = nil

  def self.context
    @@global_context || CTX_LOG
  end

  def self.context=(ctx)
    @@global_context = ctx
  end

  attr_accessor :entity_name
  attr_accessor :fields, :synthetic, :summarisable, :defsort
  attr_accessor :noun_verb, :noun_verb_fields
  attr_accessor :fieldmap, :synthmap, :table_alias

  def with
    old_context = @@global_context
    begin
      @@global_context = self
      yield
    ensure
      @@global_context = old_context
    end
  end

  def field?(field)
    field_type(field)
  end

  def raw_end_time_field
    field?('rend') ? 'rend' :
      field?('rtime') ? 'rtime' : raise "No end_time field"
  end

  def table
    GAME_PREFIXES[GameContext.game] + @table
  end

  def canonicalise_field(field)
    prefix, suffix = split_field(field)
    suffix = LGField.canonicalise_field(suffix)
    prefix ? "#{prefix}:#{suffix}" : suffix
  end

  def split_field(field)
    prefix = nil
    suffix = field
    if field =~ /^(\w+):(\w+)/
      prefix, suffix = $1, $2
    end
    [ prefix, suffix ]
  end

  def field_type(field)
    prefix, suffix = split_field(field)

    if prefix
      if prefix == @table_alias
        @fieldmap[suffix] || @synthmap[suffix]
      else
        @alt && @alt.field_type(field)
      end
    else
      @fieldmap[suffix] || @synthmap[suffix] || (@alt && @alt.field_type(field))
    end
  end

  def dbfield(field)
    raise "Bad field '#{field}'" unless field?(field)
    prefix, suffix = split_field(field)

    if @table =~ /^logrecord/ || ((!prefix || prefix == @table_alias) \
                                  && @fieldmap[suffix])
      "#@table_alias.#{LOG2SQL[suffix]}"
    else
      @alt.dbfield(field)
    end
  end

  def summarise?(field)
    prefix, suffix = split_field(field)

    if prefix
      if prefix == @table_alias
        @summarisable[suffix]
      else
        @alt && @alt.summarise?(field)
      end
    else
      @summarisable[suffix] || (@alt && @alt.summarise?(field))
    end
  end

  def initialize(table, entity_name, alt=nil)
    @table = table
    @entity_name = entity_name
    @alt = alt
    @game = GAME_TYPE_DEFAULT

    if @table =~ / (\w+)$/
      @table_alias = $1
    else
      @table_alias = @table
    end

    @noun_verb = { }
    if @table =~ /^logrecord/
      @fields = LOGFIELDS_DECORATED
      @synthetic = FAKEFIELDS_DECORATED
      @summarisable = LOGFIELDS_SUMMARISABLE
      @fieldmap = LOGFIELDS
      @synthmap = FAKEFIELDS
      @defsort = 'end'
    else
      @fields = MILEFIELDS_DECORATED
      @synthetic = FAKEFIELDS_DECORATED

      @synthmap = FAKEFIELDS.dup

      @summarisable = MILEFIELDS_SUMMARISABLE.dup
      @fieldmap = MILEFIELDS

      @defsort = 'time'
      nverbs = MILE_TYPES
      nverbs.each do |verb|
        @noun_verb[verb] = true
        @summarisable[verb] = true
        @synthmap[verb] = true
      end

      @noun_verb_fields = [ 'noun', 'verb' ]
    end
  end
end

CTX_LOG = QueryContext.new('logrecord lg', 'game')
CTX_STONE = QueryContext.new('milestone mst', 'milestone', CTX_LOG)

# Query context - can be either logrecord or milestone, NOT thread safe.
QueryContext.context = CTX_LOG

$DB_HANDLE = nil

def sql2logdate(v)
  if v.is_a?(DateTime)
    v = v.strftime('%Y-%m-%d %H:%M:%S')
  else
    v = v.to_s
  end
  if v =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/
    # Note we're munging back to POSIX month (0-11) here.
    $1 + sprintf("%02d", $2.to_i - 1) + $3 + $4 + $5 + $6 + 'S'
  else
    v
  end
end

# Given an expression that may be prefixed with '-' to be negated,
# returns a list with the first element true if the expression had a
# '-' pair and the second element being the rest of the expression.
# '+' is accepted as a do-nothing (not negated) prefix and is
# discarded.
def split_negated_expression(expr)
  if expr =~ /^([+-])(.*)/
    [$1 == '-', $2]
  else
    [false, expr]
  end
end

class SummaryFieldList
  attr_reader :fields

  def multiple_field_group?
    @fields.size > 1
  end

  def self.summary_field?(clause)
    field_regex = %r/[+-]?[a-zA-Z.0-9_:]+%?/
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
end

class SummaryField
  attr_accessor :order, :field, :percentage

  def initialize(s_clause)
    unless s_clause =~ /^([+-]?)(\S+?)(%?)$/
      raise StandardError.new("Malformed summary clause: #{s_clause}")
    end
    @order = $1.empty? ? '+' : $1
    @field = QueryContext.context..canonicalise_field($2)
    unless QueryContext.context.summarise?(@field)
      raise StandardError.new("Cannot summarise by #{@field}")
    end
    @percentage = !$3.empty?
  end

  def descending?
    @order == '+'
  end

  def sort_field
    "#{order}#{field}"
  end
end

class QueryField
  attr_accessor :expr, :field, :calias, :special, :display, :order
  def initialize(field_list, dbexpr, field, display, calias=nil, special=nil)
    @field_list = field_list
    @expr = dbexpr
    @field = field
    @display = display
    @calias = calias
    @special = special
    @type = QueryContext.context.field_type(field)
    @order = ''
  end

  def default_sort
    QuerySortCondition.new(@field_list, @display, @order == '-')
  end

  def descending?
    @order == '+'
  end

  def format_value(value)
    if @type
      return (@field == 'dur' ? pretty_duration(value.to_i) :
              @type == 'D' ? pretty_date(value) : value)
    end
    value
  end

  def to_s
    @calias ? "#{@expr} AS #{@calias}" : @expr
  end

  def aggregate?
    return expr =~ /\w+\(/
  end

  def count?
    return expr.downcase == 'count(*)'
  end

  def perc?
    return count?() && special() == :percentage
  end
end

class QueryGroupFilter
  def initialize(field, op, value)
    @field = field
    @op = op
    @opproc = FILTER_OPS[op]
    @value = value
  end

  def matches? (row)
    @opproc.call(@field.value(row), @value)
  end
end

class QuerySortField
  def initialize(field, extra)
    @field = field
    @extra = extra
    parse_field_spec
  end

  def ratio(num, den)
    num = num.to_f
    den = den.to_f
    den == 0 ? 0 : num / den
  end

  def to_s
    @field
  end

  def value(row)
    if @index.nil?
      bind_row_index!
      if row.counts && row.counts.size == 1
        @base_index = 0
      end
    end
    v = @binder.call(row)
    v
  end

  def find_extra_field_index(expr)
    index = 0
    for ef in @extra.fields do
      if ef.display == expr
        return index
      end
      index += 1
    end
    return nil
  end

  def bind_row_index!
    if @value
      @index = 0
    elsif @expr == 'n'
      @index = 1
    else
      @index = 2 + find_extra_field_index(@expr)
    end

    if !@value
      @base_index = case @base
                    when 'den'
                      0
                    when 'num'
                      1
                    when '%'
                      2
                    else
                      1
                    end
    end

    if @value
      @binder = Proc.new { |r| r.key }
    else
      extractor = if @base_index == 2
                    Proc.new { |v| ratio(v[1], v[0]) }
                  else
                    Proc.new { |v| v[@base_index] }
                  end

      if @index == 1
        @binder = Proc.new { |r| extractor.call(r.counts) }
      else
        index = @index - 2
        @binder = Proc.new { |r| extractor.call(r.extra_values[index]) }
      end
    end
  end

  def parse_field_spec
    field = @field
    if field == '.'
      @value = true
    else
      field = "#{$1}%.n" if field =~ /^(-)?%$/
      if field =~ /^(den|num|%)[.](.*)/
        @base = $1
        field = $2
      end
      @expr = field.downcase
      if @expr != 'n' && !@extra.fields.any? { |x| x.display == @expr }
        raise "Bad sort condition: '#{field}'"
      end
    end
  end
end

class QuerySortCondition
  def initialize(extra, field, reverse=true)
    @reverse = reverse
    @field = QuerySortField.new(field, extra)
  end
  def sort_value(row)
    value = @field.value(row)
  end
  def sort_cmp(a, b)
    av, bv = sort_value(a).to_f, sort_value(b).to_f
    @reverse ? av <=> bv : bv <=> av
  end
  def inspect
    "#{@field}#{@reverse ? ' (reverse)' : ''}"
  end
  def to_s
    inspect
  end
end

class QueryFieldList
  @@idbase = 0

  attr_accessor :fields, :extra
  def initialize(extra, ctx)
    extra = extra || ''
    @fields = []
    @ctx = ctx
    @extra = extra
    fields = extra.gsub(' ', '').split(',').find_all { |f| !f.empty? }
    fields.each do |f|
      @fields << parse_extra_field(f)
    end

    if not consistent?
      raise "Cannot mix aggregate and non-aggregate fields in #{extra}"
    end
    @aggregate = !@fields.empty?() && @fields[0].aggregate?()
  end

  def to_s
    "QueryFields:#{@fields.inspect}"
  end

  def parse_extra_field(f)
    order = '+'
    if f =~ /^([+-])/
      order = $1
      f = f[1 .. -1]
    end
    field = if f =~ /^(\w+)\((\w+)\)/
              aggregate_function($1, $2)
            else
              simple_field(f)
            end
    field.order = order
    field
  end

  def parse_sort_expr(expr)
    negated, expr = split_negated_expression(expr)
    QuerySortCondition.new(self, expr, negated)
  end

  def default_sorts
    @fields.map { |f| f.default_sort }
  end

  def empty?
    @fields.empty?
  end

  def aggregate?
    @aggregate
  end

  def self.unique_id()
    @@idbase += 1
    @@idbase.to_s
  end

  # Ensure that all fields are aggregate or that all fields are NOT aggregate.
  def consistent?
    return true if @fields.empty?
    aggregate = @fields[0].aggregate?
    return @fields.all? { |x| x.aggregate?() == aggregate }
  end

  def simple_field(field)
    field = field.downcase.strip
    if field == 'n'
      return QueryField.new(self, 'COUNT(*)', nil, 'N',
                            "count_" + QueryFieldList::unique_id())
    elsif field == '%'
      return QueryField.new(self, 'COUNT(*)', nil, '%',
                            "count_" + QueryFieldList::unique_id(),
                            :percentage)
    end
    @ctx.with do
      field = LGField.canonicalise_field(field)
    end
    return QueryField.new(self, field, field, field)
  end

  def aggregate_typematch(func, field)
    ftype = AGGREGATE_FUNC_TYPES[func]
    return ftype == '*' || ftype == @ctx.field_type(field)
  end

  def aggregate_function(func, field)
    @ctx.with do
      field = LGField.canonicalise_field(field)
    end
    func = canonicalise_aggregate(func)

    # And check that the types match up.
    if not aggregate_typematch(func, field)
      raise "#{func} cannot be applied to #{field}"
    end

    fieldalias = (func + "_" + field.gsub(/[^\w]+/, '_') +
                  QueryFieldList::unique_id())

    dbf = @ctx.dbfield(field)
    fieldexpr = "#{func}(#{dbf})"
    fieldexpr = "COUNT(DISTINCT #{dbf})" if func == 'cdist'
    return QueryField.new(self, fieldexpr, field,
                          "#{func}(#{field})", fieldalias)
  end

  def canonicalise_aggregate(func)
    func = func.strip.downcase
    if not AGGREGATE_FUNC_TYPES[func]
      raise "Unknown aggregate function #{func} in #{extra}"
    end
    func
  end
end

def update_tv_count(g)
  table = g['milestone'] ? 'milestone' : 'logrecord'
  sql_db_handle.do("UPDATE #{table} SET ntv = ntv + 1 " +
             "WHERE id = ?", g['id'])
end

def resolve_nick(nickexpr, default_nick)
  if self_nick?(nickexpr)
    nick = default_nick
    if nickexpr =~ /^!/
      nick = "!#{nick}"
    end
    return nick
  end
  nickexpr
end

def sql_build_query(default_nick, args,
                    context=CTX_LOG, extra_fields=nil,
                    extract_nick_from_args=true)
  #puts "sql_build_query(#{args.inspect})"

  random_game = args.find { |a| a.downcase == '-random' }
  args.delete(random_game) if random_game

  summarise = args.find { |a| SummaryFieldList.summary_field? a }
  args.delete(summarise) if summarise

  args = _op_back_combine(args)
  if extract_nick_from_args
    nick = resolve_nick(extract_nick(args), default_nick)
  else
    nick = default_nick
  end
  num  = extract_num(args)
  game = extract_game_type(args)

  GameContext.with_game(game) do
    context.with do
      q = sql_define_query(nick, num, args, extra_fields, false)
      q.summarise = SummaryFieldList.new(summarise) if summarise
      q.random_game = random_game
      q.extra_fields = extra_fields
      q.ctx = context
      q
    end
  end
end

# Parse a listgame argument string into
def sql_parse_query(default_nick, args, context=CTX_LOG)
  oargs = args.dup
  args, extra = extra_field_clause(args, context)
  args, sort_fields = extract_sort_fields(args, extra)
  args, group_filters = extract_group_filters(args, extra)

  split_args = split_query_parts(args)
  primary_args = split_args[0]

  if split_args.size > 1 && sort_fields.empty?
    sort_fields = extract_sort_fields(["o=%"], extra)[1]
  end

  nick = resolve_nick(extract_nick(primary_args), default_nick)
  primary_query = sql_build_query(nick, cloneargs(primary_args),
                                  context, extra, false)

  # Not all split queries will have an aggregate column. For instance:
  # !lg * / win has no aggregate column, but the user presumably wants to use
  # counts. In such cases, add x=n for the user.
  if split_args.size > 1 && !primary_query.summarise? && extra.empty?
    _, extra = extra_field_clause(['x=n'], context)
    primary_query = sql_build_query(nick, cloneargs(primary_args),
                                    context, extra, false)
  end

  # If the query has no sorts, but has an x=foo form => o=foo form.
  # If the query has no sorts and no x=foo, but has s=[+-]foo => o=[+-]n
  if primary_query.summarise && sort_fields.empty?
    if !extra.empty?
      sort_fields = extra.default_sorts
    else
      summary_field_list = primary_query.summarise
      sort_field = summary_field_list.fields[0]
      sort_fields = extract_sort_fields(["o=#{sort_field.order}n"], extra)[1]
    end
  end

  query_list = QueryList.new
  query_list.sorts = sort_fields
  query_list.filters = group_filters
  query_list << primary_query

  for fragment_args in split_args[1..-1] do
    combined_args = listgame_combine_argument_lists(cloneargs(primary_args),
                                                    fragment_args)
    query_list << sql_build_query(nick, combined_args,
                                  context, extra, false)
  end

  # If we have multiple queries, all must be summary queries:
  if query_list.size > 1 and !query_list.all? { |q| q.summarise? }
    raise ("Bad input: #{oargs.join(' ')}; when using /, " +
           "all query pieces must be summary queries")
  end

  query_list
end

def add_extra_fields_to_xlog_record(extra_fields, xlog_record)
  if extra_fields && !extra_fields.empty? && xlog_record
    xlog_record['extra'] = extra_fields.fields.join(",")
  end
  xlog_record
end

# Given a set of arguments of the form
#       nick num etc
# runs the query and returns the matching game.
def sql_find_game(default_nick, args, context=CTX_LOG)
  query_group = sql_parse_query(default_nick, args, context)
  query_group.with_context do
    q = query_group.primary_query
    sql_exec_query(q.num, q)
  end
end

def sql_show_game(default_nick, args, context=CTX_LOG)
  query_group = sql_parse_query(default_nick, args, context)
  query_group.with_context do
    q = query_group.primary_query
    if q.summarise?
      report_grouped_games_for_query(query_group)
    else
      result = sql_exec_query(q.num, q)
      type = context.entity_name + 's'
      if result.empty?
        puts "No #{type} for #{q.argstr}."
      else
        if block_given?
          yield result
        else
          print_game_result(result)
        end
      end
    end
  end
rescue
  puts $!
  raise
end

# Given a Henzell command's command-line, looks up a game and reports it,
# also recognising -tv and -log options.
def sql_show_game_with_extras(nick, other_args_string, extra_args = [])
  TV.with_tv_opts(other_args_string.split()[1 .. -1]) do |args, opts|
    args, logopts = extract_options(args, 'log', 'ttyrec')
    sql_show_game(ARGV[1], args + extra_args) do |res|
      if opts[:tv]
        TV.request_game_verbosely(res.qualified_index, res.game, ARGV[1])
      elsif logopts[:log]
        report_game_log(res.n, res.game)
      elsif logopts[:ttyrec]
        report_game_ttyrecs(res.n, res.game)
      else
        print_game_result(res)
      end
    end
  end
end

def row_to_fieldmap(row)
  map = { }
  (0 ... row.size).each do |i|
    lfd = QueryContext.context.fields[i]
    map[lfd.name] = lfd.value(row[i])
  end
  map
end

def index_sanity(index)
  #raise "Index too large: #{index}" if index > ROWFETCH_MAX
end

def sql_exec_query(num, q, lastcount = nil)
  origindex = num

  dbh = sql_db_handle

  # -1 is the natural index 0, -2 = 1, etc.
  num = -num - 1

  # If it looks like we have to fetch several rows, see if we can reduce
  # our work by reversing the sort order.
  count = lastcount || sql_count_rows_matching(q)
  return Sql::QueryResult.none(q) if count == 0

  if q.random_game?
    num = rand(count)
    q.random_game = false
  end

  if num < 0
    num = count + num
    raise "Index out of range: #{origindex}" if num < 0
  else
    raise "Index out of range: #{origindex}" if num >= count
  end

  if !lastcount && num > count / 2
    return sql_exec_query(num - count, q.reverse, count)
  end

  index_sanity(num)

  n = num
  sql_each_row_matching(q, n + 1) do |row|
    index = lastcount ? n + 1 : count - n
    return Sql::QueryResult.new(index, count, row, q)
  end

  Sql::QueryResult.none(q)
end

def sql_count_rows_matching(q)
  STDERR.puts "Query: #{q.select_all} (#{q.values.join(', ')})"
  sql_db_handle.get_first_value(q.select_count, *q.values).to_i
end

def sql_each_row_matching(q, limit=0)
  query = q.select_all
  if limit > 0
    if limit > 1
      query += " LIMIT 1 OFFSET #{limit - 1}"
    else
      query += " LIMIT #{limit}"
    end
  end
  sql_db_handle.execute(query, *q.values) do |row|
    yield row
  end
end

def sql_each_row_for_query(query_text, *params)
  #puts "Query: #{query_text}"
  sql_db_handle.execute(query_text, *params) do |row|
    yield row
  end
end

def sql_game_by_key(key)
  CTX_LOG.with do
    q =
      CrawlQuery.new([ 'AND', field_pred(key, '=', 'game_key') ],
                     [ ], nil, '*', 1, "gid=#{key}")
    #puts "Query: #{q.select_all}"
    r = nil
    sql_each_row_matching(q) do |row|
      r = row_to_fieldmap(row)
    end
    r
  end
end

class QueryList < Array
  attr_accessor :ctx, :sorts, :filters

  def primary_query
    self[0]
  end

  def with_context
    self[0].with_contexts do
      yield
    end
  end
end

class CrawlQuery
  attr_accessor :argstr, :nick, :num, :raw, :extra_fields, :ctx
  attr_accessor :summary_sort, :table, :game

  def initialize(predicates, sorts, extra_fields, nick, num, argstr)
    @table = QueryContext.context.table
    @pred = predicates
    @sort = sorts
    @nick = nick
    @num = num
    @extra_fields = extra_fields
    @argstr = argstr
    @values = nil
    @summarise = nil
    @random_game = nil
    @summary_sort = nil
    @raw = nil
    @joins = false
    @ctx = QueryContext.context
    @game = GameContext.game

    check_joins(predicates) if @ctx == CTX_STONE
  end

  def with_contexts
    GameContext.with_game(@game) do
      @ctx.with do
        yield
      end
    end
  end

  def has_joins?(preds)
    return false if preds.empty? || !preds.is_a?(Array)
    if preds[0].is_a?(Symbol)
      return preds[3] =~ /^#{CTX_LOG.table_alias}\./
    end
    preds.any? { |x| has_joins?(x) }
  end

  def fixup_join
    return if @joins
    @joins = true
    @table = "#@table, #{CTX_LOG.table}"
    stone_alias = CTX_STONE.table_alias
    log_alias = CTX_LOG.table_alias
    add_predicate('AND',
                  const_pred("#{stone_alias}.game_key = #{log_alias}.game_key"))
  end

  def sort_joins?
    talias = CTX_LOG.table_alias
    @sort.any? { |s| s =~ /ORDER BY #{talias}\./ }
  end

  def check_joins(preds)
    if has_joins?(preds) || sort_joins?
      fixup_join()
    end
  end

  # Is this a query aimed at a single nick?
  def single_nick?
    @nick != '*'
  end

  def summarise
    @summarise
  end

  def summarise?
    @summarise || (@extra_fields && @extra_fields.aggregate?)
  end

  def random_game?
    @random_game
  end

  def random_game=(random_game)
    @random_game = random_game
  end

  def summarise= (s)
    @summarise = s

    need_join = false
    for summary_field in @summarise.fields
      fieldname = summary_field.field
      if QueryContext.context.noun_verb[fieldname]
        noun, verb = QueryContext.context.noun_verb_fields
        # Ulch, we have to modify our predicates.
        add_predicate('AND', field_pred(fieldname, '=', verb))
        summary_field.field = noun
      end

      # If this is not a directly summarisable field, we need a join.
      if !QueryContext.context.summarisable[summary_field.field]
        fixup_join()
      end
    end

    @query = nil
  end

  def add_predicate(operator, pred)
    if @pred[0] == operator
      @pred << pred
    else
      @pred = [ operator, @pred, pred ]
    end
  end

  def select(what, with_sorts=true)
    "SELECT #{what} FROM #@table " + where(with_sorts)
  end

  def select_all
    decfields = QueryContext.context.fields
    fields = decfields.map { |x| QueryContext.context.dbfield(x.name) }.join(", ")
    "SELECT #{fields} FROM #@table " + where
  end

  def select_count
    "SELECT COUNT(*) FROM #@table " + where(false)
  end

  def summary_query
    temp = @sort
    begin
      @sort = []
      @query = nil
      sortdir = @summary_sort
      %{SELECT #{summary_fields} FROM #@table
        #{where} #{summary_group} #{summary_order}}
    ensure
      @sort = temp
    end
  end

  def summary_order
    if @summarise && !@summarise.multiple_field_group?
      "ORDER BY fieldcount #{@summary_sort}"
    else
      ''
    end
  end

  def summary_db_fields
    @summarise.fields.map { |f| QueryContext.context.dbfield(f.field) }
  end

  def summary_group
    @summarise ? "GROUP BY #{summary_db_fields.join(',')}" : ''
  end

  def summary_fields
    basefields = ''
    extras = ''
    if @summarise
      basefields = "COUNT(*) AS fieldcount, #{summary_db_fields.join(", ")}"
    end
    if @extra_fields && !@extra_fields.empty?
      # At this point extras must be aggregate columns.
      if !@extra_fields.aggregate?
        raise "Extra fields (#{@extra_fields.extra}) contain non-aggregates"
      end
      extras = @extra_fields.fields.map { |f| f.to_s }.join(", ")
    end
    [basefields, extras].find_all { |x| x && !x.empty? }.join(", ")
  end

  def query(with_sorts=true)
    build_query(with_sorts)
  end

  def values
    build_query unless @values
    @values || []
  end

  def version_predicate
    %{v #{OPERATORS['=~']} ?}
  end

  def build_query(with_sorts=true)
    @query, @values = collect_clauses(@pred)
    @query = "WHERE #{@query}" unless @query.empty?
    unless @sort.empty? or !with_sorts
      @query << " " unless @query.empty?
      @query << @sort[0]
      @query << ", #{QueryContext.context.dbfield('id')}"
    end
    @query
  end

  alias where query

  def reverse
    rq = CrawlQuery.new(@pred, reverse_sorts(@sort), @extra_fields,
                        @nick, @num, @argstr)
    rq.table = @table
    rq
  end

  def clear_sorts!
    @sort.clear
    @query = nil
  end

  def sort_by! (*fields)
    clear_sorts!
    sort = ""
    for field, direction in fields
      sort << ", " unless sort.empty?
      sort << "#{field} #{direction == :desc ? 'DESC' : ''}"
    end
    @sort << "ORDER BY #{QueryContext.context.dbfield(sort)}"
  end

  def reverse_sorts(sorts)
    sorts.map do |s|
      s =~ /\s+DESC\s*$/i ? s.sub(/\s+DESC\s*$/, '') : s + " DESC"
    end
  end

  def collect_clauses(preds)
    clauses = ''
    return clauses unless preds.size > 1

    op = preds[0]
    return [ preds[1], [ preds[2] ] ] if op == :field
    return [ preds[1], [ ] ] if op == :const

    values = []

    preds[1 .. -1].each do |p|
      clauses << " " << op << " " unless clauses.empty?

      subclause, subvalues = collect_clauses(p)
      if p[0].is_a?(Symbol)
        clauses << subclause
      else
        clauses << "(#{subclause})"
      end
      values += subvalues
    end
    [ clauses, values ]
  end
end

def const_pred(pred)
  [ :const, pred ]
end

def field_pred(v, op, fname, fexpr=nil)
  Sql::FieldPredicate.predicate(v, op, fname, fexpr)
end

def is_charabbrev? (arg)
  arg =~ /^([a-z]{2})([a-z]{2})/i && RACE_EXPANSIONS[$1.downcase] &&
    CLASS_EXPANSIONS[$2.downcase]
end

def is_race? (arg)
  RACE_EXPANSIONS[arg.downcase]
end

def is_class? (arg)
  CLASS_EXPANSIONS[arg.downcase]
end

class SummaryRowGroup
  def initialize(summary_reporter)
    @summary_reporter = summary_reporter
  end

  def sort(summary_rows)
    sorts = @summary_reporter.query_group.sorts
    #puts "Sorts: #{sorts}"
    sort_condition_exists = sorts && !sorts.empty? ? sorts[0] : nil
    if sort_condition_exists
      summary_rows.sort do |a,b|
        cmp = 0
        for sort in sorts do
          cmp = sort.sort_cmp(a, b)
          break if cmp != 0
        end
        cmp
      end
    else
      summary_rows.sort
    end
  end

  def unify(summary_rows)
    summary_field_list = @summary_reporter.query_group.primary_query.summarise
    field_count = summary_field_list.fields.size
    unify_groups(summary_field_list, 0, field_count, summary_rows)
  end

  def canonical_bucket_key(key)
    key.is_a?(String) ? key.downcase : key
  end

  def unify_groups(summary_field_list, which_group, total_groups, rows)
    current_field_spec = summary_field_list.fields[which_group]
    if which_group == total_groups - 1
      subrows = rows.map { |r|
        SummaryRow.subrow_from_fullrow(r, r.fields[-1])
      }
      subrows.each do |r|
        r.summary_field_spec = current_field_spec
      end
      return sort(subrows)
    end

    group_buckets = Hash.new do |hash, key|
      hash[key] = []
    end

    for row in rows
      group_buckets[canonical_bucket_key(row.fields[which_group])] << row
    end

    # Each bucket corresponds to a new SummaryRow that contains all its
    # children, unified:
    return sort(group_buckets.keys.map { |bucket_key|
                  bucket_subrows = group_buckets[bucket_key]
                  row = SummaryRow.subrow_from_fullrow(
                                       bucket_subrows[0],
                                       bucket_subrows[0].fields[which_group],
                                       unify_groups(summary_field_list,
                                                    which_group + 1,
                                                    total_groups,
                                                    bucket_subrows))
                  row.summary_field_spec = current_field_spec
                  row
                })
  end
end

class SummaryRow
  attr_accessor :counts, :extra_fields, :extra_values, :fields, :key
  attr_accessor :summary_field_spec, :parent
  attr_reader :subrows
  attr_reader :summary_reporter

  def initialize(summary_reporter,
                 summary_fields, count,
                 extra_fields,
                 extra_values)
    @summary_reporter = summary_reporter
    @parent = @summary_reporter

    @summary_field_spec = nil
    summarise_fields = summary_reporter.query.summarise
    @summary_field_spec = summarise_fields.fields[0] if summarise_fields
    @fields = summary_fields
    @key = summary_fields ? summary_fields.join('@@') : nil
    @counts = count.nil? ? nil : [count]
    @extra_fields = extra_fields
    @extra_values = extra_values.map { |e| [ e ] }
    @subrows = nil
  end

  def count
    @counts.nil? ? 0 : @counts[0]
  end

  def zero_counts
    @counts ? @counts.map { |x| 0 } : []
  end

  def add_count!(extra_counts)
    extra_counts.size.times do |i|
      @counts[i] += extra_counts[i]
    end
  end

  def subrows= (rows)
    @subrows = rows
    if @subrows
      @counts = zero_counts
      for row in @subrows
        row.parent = self
        add_count! row.counts
      end
    end
  end

  def self.subrow_from_fullrow(fullrow, key_override=nil, subrows=nil)
    row = SummaryRow.new(fullrow.summary_reporter,
                         [fullrow.fields[-1]],
                         fullrow.count,
                         fullrow.extra_fields,
                         fullrow.extra_values)
    row.extra_fields = fullrow.extra_fields
    row.extra_values = fullrow.extra_values
    row.counts = fullrow.counts
    row.key = key_override if key_override
    row.subrows = subrows
    row
  end

  def key
    @key.nil? ? :identity : @key
  end

  def extend!(size)
    extend_array(@counts, size)
    for ev in @extra_values do
      extend_array(ev, size)
    end
  end

  def extend_array(array, size)
    if not array.nil?
      (array.size ... size).each do
        array << 0
      end
    end
  end

  def combine!(sr)
    @counts << sr.counts[0] if not sr.counts.nil?

    extra_index = 0
    for eval in sr.extra_values do
      @extra_values[extra_index] << eval[0]
      extra_index += 1
    end
  end

  def <=> (sr)
    sr.count <=> count
  end

  def master_string
    return [counted_keys, percentage_string].find_all { |x|
      !x.empty?
    }.join(" ")
  end

  def subrows_string
    @subrows.map { |s| s.to_s }.join(", ")
  end

  def master_group_to_s
    "#{master_string} (#{subrows_string})"
  end

  def to_s
    if @subrows
      master_group_to_s
    elsif @key
      [counted_keys, percentage_string, extra_val_string].find_all { |x|
        !x.to_s.empty?
      }.join(" ")
    else
      annotated_extra_val_string
    end
  end

  def percentage_string
    if !@summary_reporter.ratio_query?
      if @summary_field_spec && @summary_field_spec.percentage
        return "(" + percentage(@counts[0], @parent.count) + ")"
      end
    end
    ""
  end

  def counted_keys
    if count_string == '1'
      key
    else
      "#{count_string}x #{@key}"
    end
  end

  def count_string
    @counts.reverse.join("/")
  end

  def extra_val_string
    allvals = []
    if @counts.size > 1
      allvals << percentage(@counts[1], @counts[0])
    end
    allvals << @extra_values.map { |x| value_string(x) }.join(";")
    es = allvals.find_all { |x| !x.empty? }.join(";")
    es.empty? ? es : "[" + es + "]"
  end

  def annotated_extra_val_string
    res = []
    index = 0
    fields = @extra_fields.fields
    @extra_values.each do |ev|
      res << annotated_value(fields[index], ev)
      index += 1
    end
    res.join("; ")
  end

  def annotated_value(field, value)
    "#{field.display}=#{value_string(value)}"
  end

  def format_value(v)
    if v.is_a?(BigDecimal) || v.is_a?(Float)
      rawv = sprintf("%.2f", v)
      rawv.sub!(/([.]\d*?)0+$/, '\1')
      rawv.sub!(/[.]$/, '')
      rawv
    else
      v
    end
  end

  def value_string(value)
    sz = value.size
    if not [1,2].index(sz)
      raise "Unexpected value array size: #{value.size}"
    end
    if sz == 1
      format_value(value[0])
    else
      short = value.reverse.join("/") + " (#{percentage(value[1], value[0])})"
    end
  end

  def percentage(num, den)
    den == 0 ? "-" : sprintf("%.2f%%", num.to_f * 100.0 / den.to_f)
  end
end

class SummaryReporter
  attr_reader :query_group

  def initialize(query_group, defval, separator, formatter)
    @query_group = query_group
    @q = query_group.primary_query
    @lq = query_group[-1]
    @defval = defval
    @sep = separator
    @extra = @q.extra_fields
    @efields = @extra ? @extra.fields : nil
    @sorted_row_values = nil
  end

  def query
    @q
  end

  def ratio_query?
    @counts &&  @counts.size == 2
  end

  def summary
    @counts = []

    for q in @query_group do
      count = sql_count_rows_matching(q)
      @counts << count
      break if count == 0
    end

    @count = @counts[0]
    if @count == 0
      "No #{summary_entities} for #{@q.argstr}"
    else
      filter_count_summary_rows!
      ("#{summary_count} #{summary_entities} " +
       "for #{@q.argstr}: #{summary_details}")
    end
  end

  def report_summary
    puts(summary)
  end

  def count
    @counts[0]
  end

  def summary_count
    if @counts.size == 1
      @count == 1 ? "One" : "#{@count}"
    else
      @counts.reverse.join("/")
    end
  end

  def summary_entities
    type = @q.ctx.entity_name
    @count == 1 ? type : type + 's'
  end

  def filter_count_summary_rows!
    group_by = @q.summarise
    summary_field_count = group_by ? group_by.fields.size : 0

    rowmap = { }
    rows = []
    query_count = @query_group.size
    first = true
    for q in @query_group do
      sql_each_row_for_query(q.summary_query, *q.values) do |row|
        srow = nil
        if group_by then
          srow = SummaryRow.new(self,
                                row[1 .. summary_field_count],
                                row[0],
                                @q.extra_fields,
                                row[(summary_field_count + 1)..-1])
        else
          srow = SummaryRow.new(self, nil, nil, @q.extra_fields, row)
        end

        if query_count > 1
          filter_key = srow.key.to_s.downcase
          if first
            rowmap[filter_key] = srow
          else
            existing = rowmap[filter_key]
            existing.combine!(srow) if existing
          end
        else
          rows << srow
        end
      end
      first = false
    end

    raw_values = query_count > 1 ? rowmap.values : rows

    if query_count > 1
      raw_values.each do |rv|
        rv.extend!(query_count)
      end
    end

    filters = @query_group.filters
    if filters
      raw_values = raw_values.find_all do |row|
        filters.all? { |f| f.matches?(row) }
      end
    end

    if summary_field_count > 1
      raw_values = SummaryRowGroup.new(self).unify(raw_values)
    else
      raw_values = SummaryRowGroup.new(self).sort(raw_values)
    end

    @sorted_row_values = raw_values
    if filters
      @counts = count_filtered_values(@sorted_row_values)
    end
  end

  def summary_details
    @sorted_row_values.join(", ")
  end

  def count_filtered_values(sorted_summary_row_values)
    counts = [0, 0]
    for summary_row_value in sorted_summary_row_values
      if summary_row_value.counts
        row_count = summary_row_value.counts
        counts[0] += row_count[0]
        if row_count.size == 2
          counts[1] += row_count[1]
        end
      end
    end
    return counts[1] == 0 ? [counts[0]] : counts
  end
end

def report_grouped_games_for_query(q, defval=nil, separator=', ', formatter=nil)
  SummaryReporter.new(q, defval, separator, formatter).report_summary
end

def report_grouped_games(group_by, defval, who, args,
                         separator=', ', formatter=nil)
  q = sql_build_query(who, args)
  q.summarise = SummaryFieldList.new("s=#{group_by}")
  query_group = QueryList.new
  query_group << q
  report_grouped_games_for_query(query_group, defval, separator, formatter)
rescue
  puts $!
  raise
end

def logfile_names
  q = "SELECT file FROM logfiles;"
  logfiles = []
  sql_db_handle.execute(q) do |row|
    logfiles << row[0]
  end
  logfiles
end

def paren_args(args)
  args && !args.empty? ? [ OPEN_PAREN ] + args + [ CLOSE_PAREN ] : []
end
