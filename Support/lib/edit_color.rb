#!/usr/bin/env ruby -wEutf-8
# Edit the #rgb color under the caret with the AppleScript color picker.
#
# 3-digit hex expands to 6 on the way out (the picker carries more bits
# than 12); 8-digit (and 4-digit) hex keeps its alpha channel untouched
# (the picker returns rgb only). Anything else — no hex, a cancelled
# picker, an unreadable result — leaves the input untouched.

require 'open3'

module EditColor
	HEX = /#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})\b/

	module_function

	def default_runner
		lambda do |script|
			out, status = Open3.capture2('osascript', '-e', script)
			[out, status.success?]
		end
	end

	def edit(input, runner = nil)
		runner ||= default_runner
		m = input.match(HEX)
		return input unless m
		body = m[1]
		body = body.chars.map { |c| c * 2 }.join if body.length <= 4
		alpha = body.length == 8 ? body[6, 2] : nil
		r, g, b = [body[0, 2], body[2, 2], body[4, 2]].map { |pair| pair.hex * 257 }
		script = 'set theColor to choose color default color {' + [r, g, b].join(', ') + '}'
		out, ok = runner.call(script)
		return input unless ok
		picked = out.match(/\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}/)
		return input unless picked
		rgb = picked.captures.map { |v| '%02x' % [[(v.to_i / 257.0).round, 0].max, 255].min }.join
		input.sub(HEX) { '#' + rgb + (alpha || '') }
	end

	def run
		print edit(STDIN.read)
	end
end

if $0 == __FILE__
	EditColor.run
end
