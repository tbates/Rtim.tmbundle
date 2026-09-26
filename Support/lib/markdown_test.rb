#!/usr/bin/env ruby -wEutf-8
require_relative 'markdown'

$failures = 0

def check(label)
	yield
rescue => e
	puts "FAIL #{label}: #{e.class}: #{e.message}"
	$failures += 1
end

# Same shape as line 12 of "test markdown Rtim unicode error.md": multibyte
# “ ” — → before the caret make the byte column larger than the char column.
LINE = "* Demand is not “super-exponential” — 800G → 1.6T. Optics can still double"

check('byte column converts to char column on unicode line') do
	char_col = LINE.index("Optics")
	byte_col = LINE[0...char_col].bytesize
	raise 'fixture has no multibyte gap' unless byte_col > char_col
	got = Markdown.byte_col_to_char_col(LINE, byte_col)
	raise "got #{got}, want #{char_col}" unless got == char_col
end

check('ascii line is identity') do
	line = "* plain ascii line with no unicode here"
	col = line.index("no unicode")
	raise unless Markdown.byte_col_to_char_col(line, col) == col
end

check('caret at column 0 or negative is 0') do
	raise unless Markdown.byte_col_to_char_col(LINE, 0) == 0
	raise unless Markdown.byte_col_to_char_col(LINE, -5) == 0
end

check('caret at end of line is line length') do
	raise unless Markdown.byte_col_to_char_col(LINE, LINE.bytesize) == LINE.length
	raise unless Markdown.byte_col_to_char_col(LINE, LINE.bytesize + 10) == LINE.length
end

check('missing line falls back to the raw column') do
	raise unless Markdown.byte_col_to_char_col(nil, 7) == 7
	raise unless Markdown.byte_col_to_char_col("", 7) == 7
end

check('break with converted column splits before Optics') do
	char_col = LINE.index("Optics")
	byte_col = LINE[0...char_col].bytesize
	pos = Markdown.byte_col_to_char_col(LINE, byte_col)
	list = Markdown::List.parse(LINE + "\n")
	list.break(0, pos)
	second = list.to_s.lines[1].to_s
	raise second.inspect unless second == "* $0Optics can still double\n"
end

check('new item prefix mirrors bullet and indent') do
	raise unless Markdown.new_item_prefix("* foo") == "* "
	raise unless Markdown.new_item_prefix("  * foo") == "  * "
	raise unless Markdown.new_item_prefix("- foo") == "- "
	raise unless Markdown.new_item_prefix("*\tfoo") == "* "
end

check('new item prefix numbers the next item') do
	raise unless Markdown.new_item_prefix("1. foo") == "2. "
	raise unless Markdown.new_item_prefix("  3. foo") == "  4. "
end

check('new item prefix gives todos a fresh box') do
	raise unless Markdown.new_item_prefix("- [ ] foo") == "- [ ] "
	raise unless Markdown.new_item_prefix("- [x] foo") == "- [ ] "
	raise unless Markdown.new_item_prefix("  - [X] foo") == "  - [ ] "
end

check('new item prefix falls back to a bullet') do
	raise unless Markdown.new_item_prefix("plain") == "* "
	raise unless Markdown.new_item_prefix(nil) == "* "
end

check('new sub-item prefix indents one level') do
	old_soft, old_size = ENV['TM_SOFT_TABS'], ENV['TM_TAB_SIZE']
	begin
		ENV['TM_SOFT_TABS'] = 'YES'
		ENV['TM_TAB_SIZE'] = '4'
		raise unless Markdown.new_item_prefix("* foo", true) == "    * "
		raise unless Markdown.new_item_prefix("  - foo", true) == "      - "
		raise unless Markdown.new_item_prefix("- [x] foo", true) == "    - [ ] "
		raise unless Markdown.new_item_prefix("plain", true) == "    * "
		ENV['TM_SOFT_TABS'] = 'NO'
		raise unless Markdown.new_item_prefix("* foo", true) == "\t* "
	ensure
		ENV['TM_SOFT_TABS'] = old_soft
		ENV['TM_TAB_SIZE'] = old_size
	end
end

check('new sub-item prefix restarts numbering at 1') do
	old_soft, old_size = ENV['TM_SOFT_TABS'], ENV['TM_TAB_SIZE']
	begin
		ENV['TM_SOFT_TABS'] = 'YES'
		ENV['TM_TAB_SIZE'] = '2'
		raise unless Markdown.new_item_prefix("1. foo", true) == "  1. "
		raise unless Markdown.new_item_prefix("3. foo", true) == "  1. "
	ensure
		ENV['TM_SOFT_TABS'] = old_soft
		ENV['TM_TAB_SIZE'] = old_size
	end
end

if $failures > 0
	puts "#{$failures} failed"
	exit 1
end
puts 'ok'
