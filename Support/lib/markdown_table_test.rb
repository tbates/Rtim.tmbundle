#!/usr/bin/env ruby -wEutf-8
require_relative 'markdown_table'

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

check('narrow multibyte characters count 1 column') do
	assert_equal(3, MarkdownTable.display_width("abc"))
	assert_equal(4, MarkdownTable.display_width("café"))
	assert_equal(8, MarkdownTable.display_width("“quoted”"))
	assert_equal(1, MarkdownTable.display_width("→"))
	assert_equal(1, MarkdownTable.display_width("✓"))
end

check('CJK and fullwidth characters count 2 columns') do
	assert_equal(4, MarkdownTable.display_width("中文"))
	assert_equal(2, MarkdownTable.display_width("あ"))
	assert_equal(2, MarkdownTable.display_width("한"))
	assert_equal(2, MarkdownTable.display_width("！"))
	assert_equal(2, MarkdownTable.display_width("😀"))
end

check('combining marks and format controls count 0 columns') do
	assert_equal(1, MarkdownTable.display_width("e\u0301"))
	assert_equal(2, MarkdownTable.display_width("a\u200Bb"))
	assert_equal(1, MarkdownTable.display_width("✓\uFE0F"))
end

check('tabbed text converts to an aligned table') do
	assert_equal("| a | b |\n|:--|:--|\n| 1 | 2 |",
		MarkdownTable.tabbed_to_table("a\tb\n1\t2"))
end

check('tabbed text strips cells and handles CRLF') do
	assert_equal("| a | b |\n|:--|:--|\n| 1 | 2 |\r\n",
		MarkdownTable.tabbed_to_table(" a \t b \r\n1\t2\r\n"))
end

check('tabbed text pads short rows to the widest row') do
	assert_equal("| a | b | c |\n|:--|:--|:--|\n| 1 |   |   |",
		MarkdownTable.tabbed_to_table("a\tb\tc\n1"))
	assert_equal("| a |   |\n|:--|:--|\n| 1 | 2 |",
		MarkdownTable.tabbed_to_table("a\n1\t2"))
end

check('tabbed text drops blank lines') do
	assert_equal("| a | b |\n|:--|:--|\n| 1 | 2 |",
		MarkdownTable.tabbed_to_table("a\tb\n\n1\t2"))
	assert_equal("", MarkdownTable.tabbed_to_table(""))
	assert_equal("", MarkdownTable.tabbed_to_table("  \n\t\n"))
end

check('normalize aligns plain columns and rebuilds the delimiter') do
	assert_equal("| a | bb |\n|:--|:---|\n| c | d  |",
		MarkdownTable.normalize("|a|bb|\n|---|---|\n|c|d|"))
end

check('normalize honours left center and right alignment') do
	assert_equal("| L    |  C  | R |\n|:-----|:---:|--:|\n| long | mid | x |",
		MarkdownTable.normalize("|L|C|R|\n|:---|:---:|---:|\n|long|mid|x|"))
end

check('normalize accepts spaced delimiters') do
	assert_equal("| a | b |\n|:--|:--|\n| c | d |",
		MarkdownTable.normalize("| a | b |\n| --- | --- |\n| c | d |"))
end

check('normalize leaves text without a delimiter row unchanged') do
	plain = "|a|b|\n|c|d|"
	assert_equal(plain, MarkdownTable.normalize(plain))
	breaked = "Title\n---\n|a|b|"
	assert_equal(breaked, MarkdownTable.normalize(breaked))
	assert_equal("", MarkdownTable.normalize(""))
end

check('normalize pads short rows and trims long rows') do
	assert_equal("| a | b |\n|:--|:--|\n| c |   |",
		MarkdownTable.normalize("|a|b|\n|---|---|\n|c|"))
	assert_equal("| a | b |\n|:--|:--|\n| c | d |",
		MarkdownTable.normalize("|a|b|\n|---|---|\n|c|d|e|"))
end

check('normalize aligns CJK cells by display width') do
	assert_equal("| café | x  |\n|:-----|:---|\n| 中文 | yy |",
		MarkdownTable.normalize("|café|x|\n|---|---|\n|中文|yy|"))
end

check('normalize gives combining marks zero width') do
	assert_equal("| e\u0301  | x  |\n|:---|:---|\n| ee | yy |",
		MarkdownTable.normalize("|e\u0301|x|\n|---|---|\n|ee|yy|"))
end

check('cells expand tabs on TM_TAB_SIZE stops') do
	old = ENV['TM_TAB_SIZE']
	begin
		ENV['TM_TAB_SIZE'] = '4'
		assert_equal(["a  b", "c"], MarkdownTable.split_row("|a\tb|c|"))
		ENV.delete('TM_TAB_SIZE')
		assert_equal(["a  b", "c"], MarkdownTable.split_row("|a\tb|c|"))
	ensure
		ENV['TM_TAB_SIZE'] = old
	end
end

check('tabbed text that is already a table just normalizes') do
	assert_equal("| Word | Code |\n|:-----|:-----|\n| café | x    |\n| 中文 | yy   |",
		MarkdownTable.tabbed_to_table("|Word|Code|\n|---|---|\n|café|x|\n|中文|yy|"))
end

check('tabbed text output is already normalized') do
	out = MarkdownTable.tabbed_to_table("Name\tScore\nTim\t42")
	assert_equal("| Name | Score |\n|:-----|:------|\n| Tim  | 42    |", out)
	assert_equal(out, MarkdownTable.normalize(out))
end

check('lone delimiter row does not crash') do
	assert_equal("|:-|", MarkdownTable.normalize("|---|"))
end

check('trailing newlines pass through both commands') do
	assert_equal("| a | b |\n|:--|:--|\n| 1 | 2 |\n",
		MarkdownTable.tabbed_to_table("a\tb\n1\t2\n"))
	assert_equal("| a | bb |\n|:--|:---|\n| c | d  |\n\n",
		MarkdownTable.normalize("|a|bb|\n|---|---|\n|c|d|\n\n"))
	assert_equal("| a | bb |\n|:--|:---|\n| c | d  |",
		MarkdownTable.normalize("|a|bb|\n|---|---|\n|c|d|"))
end

check('cursor mode normalizes the surrounding table only') do
	doc = "# Notes\n\n|Word|Code|\n|---|---|\n|café|x|\n\nDone\n"
	want = "# Notes\n\n| Word | Code |\n|:-----|:-----|\n| café | x    |\n\nDone\n"
	[3, 4, 5].each do |line_no|
		assert_equal(want, MarkdownTable.normalize_at_cursor(doc, line_no))
	end
end

check('cursor mode leaves prose and pipeless lines alone') do
	doc = "# Notes\n\n|Word|Code|\n|---|---|\n|café|x|\n\nDone\n"
	[1, 2, 6, 7].each do |line_no|
		assert_equal(doc, MarkdownTable.normalize_at_cursor(doc, line_no))
	end
	assert_equal(doc, MarkdownTable.normalize_at_cursor(doc, 0))
	assert_equal(doc, MarkdownTable.normalize_at_cursor(doc, 99))
	assert_equal("", MarkdownTable.normalize_at_cursor("", 1))
end

check('cursor mode spares pipe prose stuck to the table') do
	doc = "see a | b above\n|Word|Code|\n|---|---|\n|café|x|\n"
	want = "see a | b above\n| Word | Code |\n|:-----|:-----|\n| café | x    |\n"
	assert_equal(want, MarkdownTable.normalize_at_cursor(doc, 3))
	assert_equal(doc, MarkdownTable.normalize_at_cursor(doc, 1))
end

check('cursor mode handles tables at the document edges') do
	doc = "|b|\n|---|\n|a|"
	assert_equal("| b |\n|:--|\n| a |", MarkdownTable.normalize_at_cursor(doc, 1))
	assert_equal("| b |\n|:--|\n| a |", MarkdownTable.normalize_at_cursor(doc, 3))
end

if $failures > 0
	puts "#{$failures} failed"
	exit 1
end
puts 'ok'
