#!/usr/bin/env ruby -wEutf-8
require_relative 'theme_colors'

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

FIX = File.expand_path('Fixture.tmTheme', __dir__)

check('hex forms collapse to lowercase rrggbb / rrggbbaa') do
	assert_equal('#aabbcc', ThemeColors.normalize('#abc'))
	assert_equal('#aabbccdd', ThemeColors.normalize('#ABCD'))
	assert_equal('#4c3a6e', ThemeColors.normalize('#4C3A6E'))
	assert_equal('#db4b4b90', ThemeColors.normalize('#db4b4b90'))
	assert_equal(nil, ThemeColors.normalize('red'))
	assert_equal(nil, ThemeColors.normalize('#gg0000'))
end

check('near-gray is equal channels or one off') do
	assert_equal(true, ThemeColors.near_gray?('#3c3c3d'))
	assert_equal(true, ThemeColors.near_gray?('#1d1d1c'))
	assert_equal(true, ThemeColors.near_gray?('#242424'))
	assert_equal(false, ThemeColors.near_gray?('#4c3a6e'))
	assert_equal(false, ThemeColors.near_gray?('#ff9e64'))
end

check('Fixture groups shared colors and names the scopes') do
	inv = ThemeColors.inventory(ThemeColors.read_theme(FIX), FIX)
	assert_equal('Fixture', inv[:name])
	orange = inv[:uses]['#ff9e64'].map { |u| u.scope }
	assert_equal(['constant', 'constant.language', 'constant.numeric'], orange.compact.sort)
	gray = inv[:uses]['#e1e1e1'].map { |u| u.where }
	%w[Global Variable Markup:\ List].each do |where|
		raise "missing #{where} on #e1e1e1: #{gray.inspect}" unless gray.include?(where)
	end
	assert_equal(true, inv[:grays].include?('#3c3c3d'))
	assert_equal(true, inv[:colors].include?('#4c3a6e'))
	assert_equal(true, inv[:colors].include?('#db4b4b90'))
	assert_equal('#e1e1e1', inv[:grays].first)
	assert_equal('#111111', inv[:grays].last)
	# Opaque gray sits above the same gray with alpha.
	solid = inv[:grays].index('#242424')
	fade = inv[:grays].index('#24242460')
	raise 'alpha gray missing' if solid.nil? || fade.nil?
	raise 'alpha gray sorted above its solid' unless solid < fade
	names = inv[:colorless].map { |r| r[:where] }
	assert_equal(true, names.include?('Markup: Bold'))
	assert_equal(true, names.include?('Markup: Italic'))
end

check('chromatic colors run red toward purple, with pink beside red') do
	inv = ThemeColors.inventory(ThemeColors.read_theme(FIX), FIX)
	# The hue wheel is cut at its widest gap, so assert cyclic order
	# starting from red rather than an absolute list order.
	order = inv[:colors]
	order = order.rotate(order.index('#db4b4b'))
	%w[#db4b4b #ff9e64 #9ece6a #7aa2f7 #bb9af7].each_cons(2) do |a, b|
		raise "#{a} should precede #{b}" unless order.index(a) < order.index(b)
	end
	# Adjacency is cyclic: the wheel may start anywhere, so measure the
	# shorter way around rather than absolute list distance.
	n = order.length
	[[ '#f7768e', 'pink' ], [ '#420e14', 'dark red' ]].each do |hex, label|
		d = (order.index(hex) - order.index('#db4b4b')).abs
		raise "#{label} separated from red" unless [d, n - d].min <= 2
	end
end

check('the page carries a swatch and the scope text') do
	page = ThemeColors.page_for(FIX)
	raise 'missing swatch' unless page.include?('data-hex="#ff9e64"')
	raise 'missing scope' unless page.include?('constant.numeric')
	raise 'missing gray heading' unless page.include?('Near-grays, light to dark')
	raise 'unescaped' if page.include?('<script') && page.include?('</html>') == false
end

if $failures.zero?
	puts 'ok'
else
	puts "#{ $failures } failed"
	exit 1
end
