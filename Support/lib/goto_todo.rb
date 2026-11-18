#!/usr/bin/env ruby -wEutf-8
# goto: from a paired todo file, open the code file at the #line on this line.
#
# Naming: envy_todo.r.md sits beside envy.r. The marker is "_todo." and the
# code extension is kept, so the code path is the todo path with "_todo" removed.
# A task looks like: - [ ] fix model #34
# That opens envy.r at line 34 via txmt://open?url=file://…&line=34
# When the line has more than one #number, the one touching the caret wins,
# otherwise the last one.

module GotoTodo
  class Error < StandardError; end

  module_function

  # "/dir/envy_todo.r.md" => "/dir/envy.r"
  # "/dir/my.analysis_todo.Rmd.md" => "/dir/my.analysis.Rmd"
  def code_path(todo_path)
    dir = File.dirname(todo_path.to_s)
    base = File.basename(todo_path.to_s)
    m = base.match(/\A(.+)_todo\.(.+)\.md\z/i)
    unless m && !m[1].empty? && !m[2].empty?
      raise Error, 'Name this file like envy_todo.r.md, beside envy.r.'
    end
    File.join(dir, "#{m[1]}.#{m[2]}")
  end

  # TM_LINE_INDEX counts UTF-8 bytes. Scan indexes count characters.
  def byte_col_to_char_col(line, byte_col)
    return nil if byte_col.nil?
    byte_col = byte_col.to_i
    line = line.to_s
    return 0 if byte_col <= 0
    return line.length if byte_col >= line.bytesize
    line.byteslice(0, byte_col).length
  end

  # #34 on the line. A caret inside or just after a match selects that one.
  def line_number(text, byte_col = nil)
    line = text.to_s.sub(/\r?\n\z/, '')
    matches = []
    line.scan(/(?<!#)#(\d+)/) do
      num = Regexp.last_match[1].to_i
      matches << [Regexp.last_match.begin(0), Regexp.last_match.end(0), num]
    end
    raise Error, 'No #line on this line. Write it like: fix model #34' if matches.empty?
    caret = byte_col_to_char_col(line, byte_col)
    hit = matches.find { |b, e, _| caret && caret >= b && caret <= e } if caret
    hit ||= matches.last
    n = hit[2]
    raise Error, 'Line numbers start at 1.' if n < 1
    n
  end

  def txmt_url(path, line)
    abs = File.expand_path(path.to_s)
    esc = abs.b.gsub(/[^A-Za-z0-9.\/_-]/n) { |ch| sprintf('%%%02X', ch.ord) }
    "txmt://open?url=file://#{esc}&line=#{line.to_i}"
  end

  def target(env = ENV)
    path = env['TM_FILEPATH'].to_s
    raise Error, 'Save the todo file first.' if path.empty?
    selected = env['TM_SELECTED_TEXT'].to_s
    if selected.match?(/(?<!#)#\d+/)
      n = line_number(selected)
    else
      n = line_number(env['TM_CURRENT_LINE'].to_s, env['TM_LINE_INDEX'])
    end
    code = code_path(path)
    raise Error, "No code file at #{code}." unless File.file?(code)
    [code, n, txmt_url(code, n)]
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    _code, _n, url = GotoTodo.target
    abort "Could not open #{url}" unless system('open', url)
  rescue GotoTodo::Error => e
    abort e.message
  end
end
