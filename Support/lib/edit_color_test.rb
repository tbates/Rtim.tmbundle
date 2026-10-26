#!/usr/bin/env ruby -wEutf-8
require_relative 'edit_color'

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

def picker(result, ok = true)
	calls = []
	runner = lambda do |script|
		calls << script
		[result, ok]
	end
	[runner, calls]
end

check('6-digit round trip seeds the picker with the current color') do
	runner, calls = picker('{0, 65535, 0}')
	assert_equal("foreground = '#00ff00';", EditColor.edit("foreground = '#ff0000';", runner))
	assert_equal(['set theColor to choose color default color {65535, 0, 0}'], calls)
end

check('3-digit expands to 6') do
	runner, = picker('{65535, 0, 0}')
	assert_equal('#ff0000', EditColor.edit('#f00', runner))
end

check('8-digit keeps its alpha') do
	runner, = picker('{0, 0, 65535}')
	assert_equal('#0000ff80', EditColor.edit('#ff000080', runner))
end

check('4-digit expands to 8, keeps alpha') do
	runner, = picker('{0, 65535, 0}')
	assert_equal('#00ff0088', EditColor.edit('#f0c8', runner))
end

check('cancel keeps input') do
	runner, = picker('', false)
	assert_equal("x = '#123456';", EditColor.edit("x = '#123456';", runner))
end

check('garbage result keeps input') do
	runner, = picker('bogus')
	assert_equal("x = '#123456';", EditColor.edit("x = '#123456';", runner))
end

check('no hex keeps input and never opens the picker') do
	runner, calls = picker('{0, 0, 0}')
	assert_equal('nothing here', EditColor.edit('nothing here', runner))
	raise "picker opened: #{calls.inspect}" unless calls.empty?
end

check('5- and 7-digit runs are untouched') do
	runner, calls = picker('{0, 0, 0}')
	assert_equal('#ff000', EditColor.edit('#ff000', runner))
	assert_equal('#ff00000', EditColor.edit('#ff00000', runner))
	raise "picker opened: #{calls.inspect}" unless calls.empty?
end

check('16-to-8-bit rounding') do
	runner, = picker('{32768, 16384, 1}')
	assert_equal('#804000', EditColor.edit('#000000', runner))
end

if $failures.zero?
	puts 'ok'
else
	puts "#{ $failures } failed"
	exit 1
end
