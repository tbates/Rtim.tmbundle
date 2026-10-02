#!/usr/bin/env ruby -wEutf-8
# Table helpers behind the Rtim markdown table commands (tabbed text to
# table, normalize table). Fresh implementation. Column widths count
# monospace display columns, so CJK wide characters and combining marks
# align instead of drifting the pipes.

module MarkdownTable
  # Codepoints occupying two monospace columns: Unicode East_Asian_Width
  # W (wide) and F (fullwidth), UCD 16.0. Everything else counts one
  # column, except combining marks and format controls which are zero.
  # Arrows, check marks, and quotes count 1, matching Western rendering.
  DOUBLE_WIDTH_RANGES = [
    0x1100..0x115F,
    0x231A..0x231B,
    0x2329..0x232A,
    0x23E9..0x23EC,
    0x23F0..0x23F0,
    0x23F3..0x23F3,
    0x25FD..0x25FE,
    0x2614..0x2615,
    0x2630..0x2637,
    0x2648..0x2653,
    0x267F..0x267F,
    0x268A..0x268F,
    0x2693..0x2693,
    0x26A1..0x26A1,
    0x26AA..0x26AB,
    0x26BD..0x26BE,
    0x26C4..0x26C5,
    0x26CE..0x26CE,
    0x26D4..0x26D4,
    0x26EA..0x26EA,
    0x26F2..0x26F3,
    0x26F5..0x26F5,
    0x26FA..0x26FA,
    0x26FD..0x26FD,
    0x2705..0x2705,
    0x270A..0x270B,
    0x2728..0x2728,
    0x274C..0x274C,
    0x274E..0x274E,
    0x2753..0x2755,
    0x2757..0x2757,
    0x2795..0x2797,
    0x27B0..0x27B0,
    0x27BF..0x27BF,
    0x2B1B..0x2B1C,
    0x2B50..0x2B50,
    0x2B55..0x2B55,
    0x2E80..0x2E99,
    0x2E9B..0x2EF3,
    0x2F00..0x2FD5,
    0x2FF0..0x303E,
    0x3041..0x3096,
    0x3099..0x30FF,
    0x3105..0x312F,
    0x3131..0x318E,
    0x3190..0x31E5,
    0x31EF..0x321E,
    0x3220..0x3247,
    0x3250..0xA48C,
    0xA490..0xA4C6,
    0xA960..0xA97C,
    0xAC00..0xD7A3,
    0xF900..0xFAFF,
    0xFE10..0xFE19,
    0xFE30..0xFE52,
    0xFE54..0xFE66,
    0xFE68..0xFE6B,
    0xFF01..0xFF60,
    0xFFE0..0xFFE6,
    0x16FE0..0x16FE4,
    0x16FF0..0x16FF1,
    0x17000..0x187F7,
    0x18800..0x18CD5,
    0x18CFF..0x18D08,
    0x1AFF0..0x1AFF3,
    0x1AFF5..0x1AFFB,
    0x1AFFD..0x1AFFE,
    0x1B000..0x1B122,
    0x1B132..0x1B132,
    0x1B150..0x1B152,
    0x1B155..0x1B155,
    0x1B164..0x1B167,
    0x1B170..0x1B2FB,
    0x1D300..0x1D356,
    0x1D360..0x1D376,
    0x1F004..0x1F004,
    0x1F0CF..0x1F0CF,
    0x1F18E..0x1F18E,
    0x1F191..0x1F19A,
    0x1F200..0x1F202,
    0x1F210..0x1F23B,
    0x1F240..0x1F248,
    0x1F250..0x1F251,
    0x1F260..0x1F265,
    0x1F300..0x1F320,
    0x1F32D..0x1F335,
    0x1F337..0x1F37C,
    0x1F37E..0x1F393,
    0x1F3A0..0x1F3CA,
    0x1F3CF..0x1F3D3,
    0x1F3E0..0x1F3F0,
    0x1F3F4..0x1F3F4,
    0x1F3F8..0x1F43E,
    0x1F440..0x1F440,
    0x1F442..0x1F4FC,
    0x1F4FF..0x1F53D,
    0x1F54B..0x1F54E,
    0x1F550..0x1F567,
    0x1F57A..0x1F57A,
    0x1F595..0x1F596,
    0x1F5A4..0x1F5A4,
    0x1F5FB..0x1F64F,
    0x1F680..0x1F6C5,
    0x1F6CC..0x1F6CC,
    0x1F6D0..0x1F6D2,
    0x1F6D5..0x1F6D7,
    0x1F6DC..0x1F6DF,
    0x1F6EB..0x1F6EC,
    0x1F6F4..0x1F6FC,
    0x1F7E0..0x1F7EB,
    0x1F7F0..0x1F7F0,
    0x1F90C..0x1F93A,
    0x1F93C..0x1F945,
    0x1F947..0x1F9FF,
    0x1FA70..0x1FA7C,
    0x1FA80..0x1FA89,
    0x1FA8F..0x1FAC6,
    0x1FACE..0x1FADC,
    0x1FADF..0x1FAE9,
    0x1FAF0..0x1FAF8,
    0x20000..0x2FFFD,
    0x30000..0x3FFFD,
  ].freeze

  # Monospace columns str occupies.
  def MarkdownTable.display_width(str)
    width = 0
    str.each_char do |ch|
      if ch.match?(/\p{M}|\p{Cf}/)
        next
      elsif DOUBLE_WIDTH_RANGES.any? { |range| range.cover?(ch.ord) }
        width += 2
      else
        width += 1
      end
    end
    width
  end

  # Expand tabs to spaces honouring TM_TAB_SIZE tab stops.
  def MarkdownTable.expand_tabs(str)
    size = ENV.fetch("TM_TAB_SIZE", "").to_i
    size = 4 if size <= 0
    out = +""
    col = 0
    str.each_char do |ch|
      if ch == "\t"
        gap = size - (col % size)
        out << " " * gap
        col += gap
      else
        out << ch
        col += display_width(ch)
      end
    end
    out
  end

  SEPARATOR_CHARS = ["|", "-", ":", " "].freeze

  # A GitHub delimiter row: pipes and dashes with optional alignment
  # colons and spaces. A bare --- (a thematic break) does not count.
  def MarkdownTable.separator_row?(line)
    s = line.strip
    return false if s.empty?
    return false unless s.include?("|") && s.include?("-")
    s.each_char.all? { |ch| SEPARATOR_CHARS.include?(ch) }
  end

  def MarkdownTable.column_alignment(cell)
    left = cell.start_with?(":")
    right = cell.end_with?(":")
    return :center if left && right
    return :right if right
    :left
  end

  # Split a table line into stripped cells: edge pipes removed, tabs
  # expanded, one entry per column even when empty.
  def MarkdownTable.split_row(line)
    s = expand_tabs(line.strip)
    s = s.sub(/\A\|/, "").sub(/\|\z/, "")
    s.split("|", -1).map(&:strip)
  end

  # Pad cell text (bumpers included) out to a display width.
  def MarkdownTable.pad_cell(text, width, alignment)
    gap = width - display_width(text)
    gap = 0 if gap.negative?
    case alignment
    when :right
      " " * gap + text
    when :center
      left = gap / 2
      " " * left + text + " " * (gap - left)
    else
      text + " " * gap
    end
  end

  def MarkdownTable.delimiter_cell(alignment, width)
    case alignment
    when :center
      ":" + "-" * (width - 2) + ":"
    when :right
      "-" * (width - 1) + ":"
    else
      ":" + "-" * (width - 1)
    end
  end

  # Turn tab-separated lines into a GitHub table: pipes around every
  # line, blank lines dropped, a -- delimiter row after the header.
  # The widest row sets the column count; short rows gain empty cells.
  # The result is normalized before return, so one command produces an
  # aligned table. Trailing newlines pass through, so replacing a line
  # selection keeps the line break that followed it. Input holding a
  # delimiter row is already a table, so it is normalized as-is.
  def MarkdownTable.tabbed_to_table(text)
    return normalize(text) if text.each_line.any? { |line| separator_row?(line) }
    rows = []
    text.each_line do |line|
      cells = line.chomp.split("\t", -1).map(&:strip)
      rows << cells unless cells.all?(&:empty?)
    end
    return "" if rows.empty?
    count = rows.map(&:length).max
    rows.each { |row| row.fill("", row.length, count - row.length) }
    body = rows.map { |row| "|" + row.join("|") + "|" }
    body.insert(1, "|" + (["--"] * count).join("|") + "|")
    normalize(body.join("\n")) + text[/(\r?\n)*\z/]
  end

  # Align the pipes of a GitHub table: one space bumper inside every
  # cell, columns padded per the delimiter row alignment, delimiter
  # rebuilt to the measured widths. Text without a delimiter row is
  # returned unchanged. Trailing newlines pass through, so replacing a
  # line selection keeps the line break that followed it.
  def MarkdownTable.normalize(text)
    lines = text.split(/\r?\n/)
    found = lines.index { |line| separator_row?(line) }
    return text if found.nil?
    ending = text[/(\r?\n)*\z/]
    alignments = split_row(lines[found]).map { |cell| column_alignment(cell) }
    count = alignments.length
    rows = []
    lines.each_with_index do |line, i|
      next if i == found
      row = split_row(line)
      row = row[0, count] + [""] * [count - row.length, 0].max
      rows << row
    end
    widths = Array.new(count, 2)
    rows.each do |row|
      row.each_with_index do |cell, i|
        wide = display_width(" " + cell + " ")
        widths[i] = wide if wide > widths[i]
      end
    end
    body = rows.map do |row|
      "|" + row.each_with_index.map { |cell, i|
        pad_cell(" " + cell + " ", widths[i], alignments[i])
      }.join("|") + "|"
    end
    body.insert(found, "|" + alignments.each_with_index.map { |a, i|
      delimiter_cell(a, widths[i])
    }.join("|") + "|")
    body.join("\n") + ending
  end

  # Normalize the table surrounding a 1-based document line number: the
  # contiguous run of pipe-bearing lines around it, trimmed above to the
  # header over the first delimiter row. A cursor outside any table, or
  # a line number outside the document, returns the text unchanged.
  def MarkdownTable.normalize_at_cursor(doc, line_no)
    lines = doc.split("\n", -1)
    at = line_no - 1
    return doc if at < 0 || at >= lines.length
    return doc unless lines[at].include?("|")
    top = at
    top -= 1 while top > 0 && lines[top - 1].include?("|")
    bottom = at
    bottom += 1 while bottom + 1 < lines.length && lines[bottom + 1].include?("|")
    found = (top..bottom).find { |i| separator_row?(lines[i]) }
    return doc if found.nil?
    top = found - 1 if found - 1 > top
    return doc if at < top
    extent = lines[top..bottom].join("\n")
    lines[top..bottom] = normalize(extent).split("\n", -1)
    lines.join("\n")
  end
end
