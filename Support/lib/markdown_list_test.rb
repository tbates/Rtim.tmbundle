#!/usr/bin/env ruby -wEutf-8
require_relative 'markdown_list'

$failures = 0

def check(label)
	yield
rescue => e
	puts "FAIL #{label}: #{e.class}: #{e.message}"
	$failures += 1
end

def assert_equal(want, got)
	raise "want #{want.inspect}, got #{got.inspect}" unless want == got
end

# Same shape as line 12 of "test markdown Rtim unicode error.md": multibyte
# “ ” — → before the caret make the byte column larger than the char column.
LINE = "* Demand is not “super-exponential” — 800G → 1.6T. Optics can still double"

check('byte column converts to char column on unicode line') do
	char_col = LINE.index("Optics")
	byte_col = LINE[0...char_col].bytesize
	raise 'fixture has no multibyte gap' unless byte_col > char_col
	got = MarkdownList.byte_col_to_char_col(LINE, byte_col)
	raise "got #{got}, want #{char_col}" unless got == char_col
end

check('ascii line is identity') do
	line = "* plain ascii line with no unicode here"
	col = line.index("no unicode")
	raise unless MarkdownList.byte_col_to_char_col(line, col) == col
end

check('caret at column 0 or negative is 0') do
	raise unless MarkdownList.byte_col_to_char_col(LINE, 0) == 0
	raise unless MarkdownList.byte_col_to_char_col(LINE, -5) == 0
end

check('caret at end of line is line length') do
	raise unless MarkdownList.byte_col_to_char_col(LINE, LINE.bytesize) == LINE.length
	raise unless MarkdownList.byte_col_to_char_col(LINE, LINE.bytesize + 10) == LINE.length
end

check('missing line falls back to the raw column') do
	raise unless MarkdownList.byte_col_to_char_col(nil, 7) == 7
	raise unless MarkdownList.byte_col_to_char_col("", 7) == 7
end

check('break with converted column splits before Optics') do
	char_col = LINE.index("Optics")
	byte_col = LINE[0...char_col].bytesize
	pos = MarkdownList.byte_col_to_char_col(LINE, byte_col)
	out = MarkdownList.break_item(LINE + "\n", 0, pos)
	second = out.lines[1].to_s
	raise second.inspect unless second == "* $0Optics can still double\n"
end

check('new item prefix mirrors bullet and indent') do
	raise unless MarkdownList.new_item_prefix("* foo") == "* "
	raise unless MarkdownList.new_item_prefix("  * foo") == "  * "
	raise unless MarkdownList.new_item_prefix("- foo") == "- "
	raise unless MarkdownList.new_item_prefix("*\tfoo") == "* "
end

check('new item prefix numbers the next item') do
	raise unless MarkdownList.new_item_prefix("1. foo") == "2. "
	raise unless MarkdownList.new_item_prefix("  3. foo") == "  4. "
end

check('new item prefix gives todos a fresh box') do
	raise unless MarkdownList.new_item_prefix("- [ ] foo") == "- [ ] "
	raise unless MarkdownList.new_item_prefix("- [x] foo") == "- [ ] "
	raise unless MarkdownList.new_item_prefix("  - [X] foo") == "  - [ ] "
end

check('new item prefix falls back to a bullet') do
	raise unless MarkdownList.new_item_prefix("plain") == "* "
	raise unless MarkdownList.new_item_prefix(nil) == "* "
end

check('new sub-item prefix indents one level') do
	old_soft, old_size = ENV['TM_SOFT_TABS'], ENV['TM_TAB_SIZE']
	begin
		ENV['TM_SOFT_TABS'] = 'YES'
		ENV['TM_TAB_SIZE'] = '4'
		raise unless MarkdownList.new_item_prefix("* foo", true) == "    * "
		raise unless MarkdownList.new_item_prefix("  - foo", true) == "      - "
		raise unless MarkdownList.new_item_prefix("- [x] foo", true) == "    - [ ] "
		raise unless MarkdownList.new_item_prefix("plain", true) == "    * "
		ENV['TM_SOFT_TABS'] = 'NO'
		raise unless MarkdownList.new_item_prefix("* foo", true) == "\t* "
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
		raise unless MarkdownList.new_item_prefix("1. foo", true) == "  1. "
		raise unless MarkdownList.new_item_prefix("3. foo", true) == "  1. "
	ensure
		ENV['TM_SOFT_TABS'] = old_soft
		ENV['TM_TAB_SIZE'] = old_size
	end
end

check('break at end of line opens an item below') do
	assert_equal("* ab\n* $0\n* cd\n",
		MarkdownList.break_item("* ab\n* cd\n", 0, 4))
end

check('break mid-line carries the tail into the new item') do
	assert_equal("* a\n* $0b\n* cd\n",
		MarkdownList.break_item("* ab\n* cd\n", 0, 3))
end

check('break before content inserts an empty item above') do
	assert_equal("* $0\n* ab\n* cd\n",
		MarkdownList.break_item("* ab\n* cd\n", 0, 0))
end

check('break inside a sublist keeps the indent') do
	assert_equal("* a\n  * b\n  * $0\n  * c\n* d\n",
		MarkdownList.break_item("* a\n  * b\n  * c\n* d\n", 1, 5))
end

check('break renumbers numbered lists') do
	assert_equal("1. a\n2. $0\n3. b\n",
		MarkdownList.break_item("1. a\n2. b\n", 0, 4))
end

check('break gives todos a fresh box') do
	assert_equal("- [ ] task\n- [ ] $0\n- [x] done\n",
		MarkdownList.break_item("- [ ] task\n- [x] done\n", 0, 10))
	assert_equal("- [ ] ta\n- [ ] $0sk\n",
		MarkdownList.break_item("- [ ] task\n", 0, 8))
end

check('subitem break nests one level deeper') do
	old_soft, old_size = ENV['TM_SOFT_TABS'], ENV['TM_TAB_SIZE']
	begin
		ENV['TM_SOFT_TABS'] = 'YES'
		ENV['TM_TAB_SIZE'] = '4'
		assert_equal("* a\n    * $0\n* b\n",
			MarkdownList.break_item("* a\n* b\n", 0, 4, true))
		assert_equal("1. a\n    1. $0\n2. b\n",
			MarkdownList.break_item("1. a\n2. b\n", 0, 4, true))
		assert_equal("- [ ] t\n    - [ ] $0\n",
			MarkdownList.break_item("- [ ] t\n", 0, 8, true))
		assert_equal("    * $0\n* ab\n",
			MarkdownList.break_item("* ab\n", 0, 0, true))
	ensure
		ENV['TM_SOFT_TABS'] = old_soft
		ENV['TM_TAB_SIZE'] = old_size
	end
end

check('break keeps every item marker') do
	assert_equal("- a\n* b\n* $0\n",
		MarkdownList.break_item("- a\n* b\n", 1, 3))
end

check('break splits continuation lines into new items') do
	assert_equal("* a\n  cont \n* $0here\n* b\n",
		MarkdownList.break_item("* a\n  cont here\n* b\n", 1, 7))
end

check('break leaves leading prose and stray lines alone') do
	assert_equal("junk\n* a\n* $0\n",
		MarkdownList.break_item("junk\n* a\n", 1, 3))
	assert_equal("junk\n* a\n",
		MarkdownList.break_item("junk\n* a\n", 0, 2))
	assert_equal("* a\n",
		MarkdownList.break_item("* a\n", 5, 0))
end

check('break on empty input returns empty') do
	assert_equal("", MarkdownList.break_item("", 0, 0))
end

check('break output ends with a newline') do
	assert_equal("* ab\n* $0\n",
		MarkdownList.break_item("* ab", 0, 4))
end

check('break escapes content but not the cursor') do
	out = MarkdownList.break_item("* a$b\n", 0, 5) { |s| s.gsub("$", "\\$") }
	assert_equal("* a\\$b\n* $0\n", out)
end

check('lines to items prefixes every line once') do
	assert_equal("${1:*} alpha\n${1:*} beta\n",
		MarkdownList.lines_to_items("alpha\nbeta\n"))
	assert_equal("${1:*} alpha\n${1:*} beta",
		MarkdownList.lines_to_items("alpha\nbeta"))
end

check('lines to items spares blanks and empties') do
	assert_equal("${1:*} alpha\n\n${1:*} beta\n",
		MarkdownList.lines_to_items("alpha\n\nbeta\n"))
	assert_equal("", MarkdownList.lines_to_items(""))
end

check('list to todos converts markers and plain lines') do
	assert_equal(
		"- [ ] a\n- [ ] b\n- [ ] c\n- [ ] d\n- [x] e\n- [x] f\n- [ ] g\n- [ ] plain\n  - [ ] h\n\n",
		MarkdownList.list_to_todos("- a\n* b\n1. c\n+ d\n- [x] e\n- [X] f\n* [ ] g\nplain\n  - h\n\n"))
	assert_equal("- [ ] a", MarkdownList.list_to_todos("a"))
	assert_equal("", MarkdownList.list_to_todos(""))
end

if $failures > 0
	puts "#{$failures} failed"
	exit 1
end
puts 'ok'
