require 'query/keyword_matcher'

module Query
  # These matches are applied in sequence, order is significant.

  KeywordMatcher.matcher(:nick) {
    'name' if arg =~ /^@/
  }

  KeywordMatcher.matcher(:char_abbrev) {
    'char' if is_charabbrev?(arg)
  }

  KeywordMatcher.matcher(:race_or_class) {
    if arg =~ /^[a-z]{2}$/i then
      cls = is_class?(arg)
      sp = is_race?(arg)
      return expr.parse('cls', arg) if cls && !sp
      return expr.parse('race', arg) if sp && !cls
      if cls && sp
        raise "#{arg} is ambiguous -- may be interpreted as species or class"
      end
    end
  }

  KeywordMatcher.matcher(:god) {
    god_name = GODS.god_resolve_name(arg)
    return expr.parse('god', god_name) if god_name
  }

  KeywordMatcher.matcher(:ktyp) {
    ktyp_matches = SQL_CONFIG['prefix-field-fixups']['ktyp']
    match = ktyp_matches.keys.find { |ktyp| arg =~ /^#{ktyp}\w*$/i }
    return expr.parse('ktyp', ktyp_matches[match]) if match
  }

  KeywordMatcher.matcher(:boring) {
    if %w/boring bore/.include?(arg.downcase)
      return expr.parse('ktyp', 'leaving|quitting')
    end
  }

  KeywordMatcher.matcher(:version) {
    if arg =~ /^\d+[.]\d+([.]\d+)*(?:-\w+\d*)?$/
      return arg =~ /^\d+[.]\d+(?:$|-)/ ? 'cv' : 'v'
    end
  }

  KeywordMatcher.matcher(:source) {
    SOURCES.index(arg.downcase) && 'src'
  }

  KeywordMatcher.matcher(:branch) {
    'place' if BRANCHES.branch?(arg)
  }

  KeywordMatcher.matcher(:tourney) {
    'when' if tourney_keyword?(arg)
  }

  KeywordMatcher.matcher(:rune_type) {
    'verb' if context.value_key?(arg)
  }

  KeywordMatcher.matcher(:boolean) {
    return unless value_field.known?
    if value_field.boolean?
      return expr.parse(value.downcase, 'y')
    end
    if value_field.text?
      return expr.parse(value.downcase, '', expr.op.negate)
    end
  }
end
