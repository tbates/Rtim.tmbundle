#!/usr/bin/env ruby -wEutf-8
# List helpers behind the Rtim markdown list commands (new item, new
# subitem, lines to items, list to todos). Fresh implementation.

module MarkdownList
  # TM_LINE_INDEX counts UTF-8 bytes; Ruby 2+ String indexing counts characters.
  # Convert a TextMate byte column into a character column for break_item.
  def MarkdownList.byte_col_to_char_col(line, byte_col)
    line = line.to_s
    return 0 if byte_col <= 0
    return byte_col if line.empty?
    return line.length if byte_col >= line.bytesize
    line.byteslice(0, byte_col).length
  end

  # Prefix for a new list item mirroring the given line: its indent and
  # bullet, the next number for numbered lists, a fresh box for todos.
  # With sub=true, one indent level deeper and numbered lists restart at 1.
  def MarkdownList.new_item_prefix(line, sub = false)
    line = line.to_s
    unit = ""
    if sub
      unit = ENV['TM_SOFT_TABS'] == 'NO' ? "\t" : " " * ENV['TM_TAB_SIZE'].to_i
    end
    if (m = line.match(/^(\s*-\s*\[.\]\s*)/))
      return unit + m[1].sub(/\[.\]/, "[ ]").sub(/\s*\z/, " ")
    end
    if (m = line.match(/^(\s*)([0-9]+)(\.\s*)/))
      num = sub ? 1 : m[2].to_i + 1
      return "#{unit}#{m[1]}#{num}. "
    end
    if (m = line.match(/^(\s*(?:\*|-)\s*)/))
      return unit + m[1].sub(/\s*\z/, " ")
    end
    unit + "* "
  end

  # Split a physical line into indent, marker core, gap, and body. A
  # marker needs whitespace (or end of line) after it; "*b" is text.
  def MarkdownList.parse_item_line(line)
    m = /\A([ \t]*)([-*+]|\d+\.)([ \t]*)(.*)\z/.match(line)
    return nil if m.nil?
    return nil if m[3].empty? && !m[4].empty?
    { indent: m[1], core: m[2], gap: m[3], body: m[4] }
  end

  # Group physical lines into leading prose plus items carrying their
  # continuation lines. Markers of any shape start their own item, so
  # mixed - * + and numbered markers all survive the round trip.
  def MarkdownList.parse_list(lines)
    preamble = []
    items = []
    current = nil
    lines.each do |line|
      parsed = parse_item_line(line)
      if parsed
        current = {
          indent: parsed[:indent], core: parsed[:core],
          gap: parsed[:gap], head: parsed[:body], extra: [],
        }
        items << current
      elsif current
        current[:extra] << line
      else
        preamble << line
      end
    end
    [preamble, items]
  end

  # One indent level deeper, honouring TextMate tab settings.
  def MarkdownList.deeper_indent(indent)
    if ENV['TM_SOFT_TABS'] == 'NO'
      "\t#{indent}"
    else
      " " * ENV['TM_TAB_SIZE'].to_i + indent
    end
  end

  # A todo item wears "- " plus a checkbox; anything else is plain.
  def MarkdownList.todo_item?(core, body)
    core == "-" && body.lstrip.match?(/\A\[.\]/)
  end

  # Split the item holding physical line `line` at character column
  # `col` (full-line coordinates, indent included), inserting a new
  # item that carries the text after the split. With subitem set, the
  # new item nests one level deeper and numbered lists restart at 1.
  # A split before any content inserts an empty item above instead.
  # The escape block prepares content for snippet output; the $0
  # cursor marker bypasses it. Output always ends with one newline;
  # a line outside any item passes through unchanged.
  def MarkdownList.break_item(text, line, col, subitem = false, &escape)
    escape ||= ->(s) { s }
    lines = text.lines.map(&:chomp)
    return "" if lines.empty?
    return lines.join("\n") + "\n" unless line.between?(0, lines.length - 1)
    preamble, items = parse_list(lines)

    at = preamble.length
    found_ii = nil
    found_k = nil
    items.each_with_index do |item, ii|
      if line == at
        found_ii, found_k = ii, nil
        break
      end
      at += 1
      item[:extra].each_with_index do |_, k|
        if line == at
          found_ii, found_k = ii, k
          break
        end
        at += 1
      end
      break unless found_ii.nil?
    end
    return lines.join("\n") + "\n" if found_ii.nil?

    item = items[found_ii]
    if found_k.nil?
      prefix = item[:indent] + item[:core]
      region = item[:gap] + item[:head]
      before = []
      after = item[:extra]
    else
      prefix = ""
      region = item[:extra][found_k]
      before = [item[:indent] + item[:core] + item[:gap] + item[:head]] +
        item[:extra][0...found_k]
      after = item[:extra][found_k + 1..-1]
    end

    rel = col - prefix.length
    head_str = rel <= 0 ? "" : region[0...rel].to_s
    tail = (rel <= 0 ? region : region[rel..-1].to_s).lstrip
    first_blank = (before + [head_str]).all? { |s| s.strip.empty? }
    second_blank = ([tail] + after).all? { |s| s.strip.empty? }

    todo = todo_item?(item[:core], item[:gap] + item[:head])
    box = todo ? "[ ] " : ""
    out = lines.map { |s| [s] }
    if first_blank && !second_blank
      dent = subitem ? deeper_indent(item[:indent]) : item[:indent]
      out.insert(line, ["#{dent}#{item[:core]} #{box}", :cursor])
    else
      dent = subitem ? deeper_indent(item[:indent]) : item[:indent]
      clean_tail = todo ? tail.sub(/\A\[.\] +/, "") : tail
      out[line] = [prefix + head_str]
      out.insert(line + 1, ["#{dent}#{item[:core]} #{box}", :cursor, clean_tail])
    end

    counters = Hash.new(0)
    out = out.map do |segs|
      plain = segs.map { |s| s == :cursor ? "" : s }.join
      parsed = parse_item_line(plain)
      if parsed && parsed[:core] =~ /\A\d+\.\z/
        counters[parsed[:indent]] += 1
        number = "#{parsed[:indent]}#{counters[parsed[:indent]]}."
        if segs.include?(:cursor)
          rest = segs[segs.index(:cursor) + 1..-1].join
          [number + " ", :cursor, rest]
        else
          ["#{number}#{parsed[:gap]}#{parsed[:body]}"]
        end
      else
        segs
      end
    end

    out.map { |segs|
      segs.map { |s| s == :cursor ? "$0" : escape.call(s) }.join
    }.join("\n") + "\n"
  end

  # Prefix every non-blank line with a ${1:*} snippet tab stop, so one
  # keystroke turns lines into list items and one edit picks the marker.
  # Blank lines and trailing newlines pass through untouched.
  def MarkdownList.lines_to_items(text)
    lines = text.split("\n")
    return "" if lines.empty?
    body = lines.map { |line| line.strip.empty? ? line : "${1:*} #{line}" }
    body.join("\n") + text[/(\r?\n)*\z/]
  end

  # Convert a Markdown list (or plain lines) into a GitHub-style task list.
  # - item / * item / 1. item  →  - [ ] item
  # Existing - [x] / - [ ] items are normalized; blank lines kept; indent preserved.
  def MarkdownList.list_to_todos(text)
    lines = text.split("\n", -1)
    out = lines.map do |line|
      if line.strip.empty?
        line
      elsif line =~ /\A(\s*)(?:[-*+]|\d+\.)\s+\[([ xX])\]\s+(.*)\z/
        indent, check, rest = $1, $2, $3
        box = check.downcase == 'x' ? 'x' : ' '
        "#{indent}- [#{box}] #{rest}"
      elsif line =~ /\A(\s*)(?:[-*+]|\d+\.)\s+(.*)\z/
        indent, rest = $1, $2
        if rest =~ /\A\[([ xX])\]\s+(.*)\z/
          box = $1.downcase == 'x' ? 'x' : ' '
          "#{indent}- [#{box}] #{$2}"
        else
          "#{indent}- [ ] #{rest}"
        end
      else
        indent = line[/^\s*/]
        "#{indent}- [ ] #{line.lstrip}"
      end
    end
    out.join("\n")
  end
end
