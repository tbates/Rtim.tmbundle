#!/usr/bin/env ruby -wEutf-8
require_relative 'roxygen_stub'

$failures = 0

def check(label)
	yield
rescue RoxygenStub::Error => e
	puts "FAIL #{label}: unexpected error: #{e.message}"
	$failures += 1
rescue => e
	puts "FAIL #{label}: #{e.class}: #{e.message}"
	$failures += 1
end

def expect_error(label, text)
	begin
		RoxygenStub.parse(text)
		puts "FAIL #{label}: expected an error"
		$failures += 1
	rescue RoxygenStub::Error
	end
end

check('assignment and two args') do
	h = RoxygenStub.parse('fun <- function(x, y)')
	raise 'name' unless h.name == 'fun'
	raise h.args.inspect unless h.args.map(&:name) == ['x', 'y']
	raise 'default' unless h.args.all? { |a| a.default.nil? }
end

check('equals and <<-') do
	raise unless RoxygenStub.parse('fun = function(x)').name == 'fun'
	raise unless RoxygenStub.parse('fun <<- function(x)').name == 'fun'
end

check('backtick and quoted names') do
	raise unless RoxygenStub.parse("`odd name` <- function(x)").name == '`odd name`'
	raise unless RoxygenStub.parse('"odd" = function(x)').name == '"odd"'
end

check('anonymous') do
	h = RoxygenStub.parse('function(x, y)')
	raise 'named' unless h.name.nil?
	raise h.args.map(&:name).inspect unless h.args.map(&:name) == ['x', 'y']
end

check('comma inside default') do
	h = RoxygenStub.parse('fun <- function(x = c(1, 2), y = "a,b", z = list(1, 2))')
	raise h.args.map(&:name).inspect unless h.args.map(&:name) == ['x', 'y', 'z']
	raise h.args[0].default.inspect unless h.args[0].default == 'c(1, 2)'
	raise h.args[1].default.inspect unless h.args[1].default == '"a,b"'
	raise h.args[2].default.inspect unless h.args[2].default == 'list(1, 2)'
end

check('multiline and dots') do
	h = RoxygenStub.parse("fun <- function(x,\n  y = 1,\n  ...)")
	raise h.args.map(&:name).inspect unless h.args.map(&:name) == ['x', 'y', '...']
	raise h.args[1].default.inspect unless h.args[1].default == '1'
end

check('nested function is a default, not the header') do
	h = RoxygenStub.parse('fun <- function(x = function(y) y + 1, z)')
	raise h.args.map(&:name).inspect unless h.args.map(&:name) == ['x', 'z']
end

check('comment in the header is not an argument') do
	h = RoxygenStub.parse("fun <- function(x, # note\n  y)")
	raise h.args.map(&:name).inspect unless h.args.map(&:name) == ['x', 'y']
end

expect_error('equals banner', '# ===== #')
expect_error('unclosed', 'fun <- function(x, y')
expect_error('blank', '   ')

check('snippet fills name, params, and keeps the header') do
	h = RoxygenStub.parse("fun <- function(x, y = 1)")
	s = RoxygenStub.snippet(h)
	raise s unless s.include?("#' ${1:Take care of your golden goose}")
	raise 'desc' unless s.include?("#' \\`fun\\` takes a x and y to return a ${2:}")
	raise 'param x' unless s.include?("#' @param x ${3:}")
	raise 'param y' unless s.include?("#' @param y ${4:Default \\`1\\`.}")
	raise 'examples' unless s.include?("#' fun(x, y)")
	raise 'header lost' unless s.end_with?("fun <- function(x, y = 1)")
end

check('dollar in the header is escaped') do
	h = RoxygenStub.parse('fun <- function(x = "$")')
	s = RoxygenStub.snippet(h)
	raise s unless s.include?('fun <- function(x = "\\$")')
end

check('anonymous name is a placeholder') do
	s = RoxygenStub.snippet(RoxygenStub.parse('function()'))
	raise s unless s.include?('${2:myfunc}')
	raise s unless s.include?("#' ${2:myfunc}()")
end

if $failures > 0
	puts "#{$failures} failed"
	exit 1
end
puts 'ok'
