#!/usr/bin/env ruby -wEutf-8
# Build a roxygen stub from an R function header.
# The header is the selection, or the current line. The argument list must
# be closed inside that text; the rest of the file is not read.

module RoxygenStub
	class Error < StandardError; end
	Arg = Struct.new(:name, :default)
	Header = Struct.new(:name, :args, :raw)

	module_function

	def parse(text)
		src = text.to_s
		raise Error, 'Select the function header, or put the caret on its line.' if src.strip.empty?
		fn = index_of_function(src)
		raise Error, 'Select the function header, or put the caret on its line.' unless fn
		paren = index_after_ws(src, fn + 'function'.length)
		unless paren && src[paren] == '('
			raise Error, 'Select the function header, or put the caret on its line.'
		end
		close = match_closer(src, paren)
		raise Error, 'Select the whole function header. The argument list is not closed.' unless close
		Header.new(name_before(src, fn), split_args(src[(paren + 1)...close]), src)
	end

	def snippet(header)
		n = 1
		name_lit = header.name
		if name_lit
			name_bits = [snippet_literal(display_name(name_lit))]
		else
			n += 1
			name_bits = ["${#{n}:myfunc}"]
			# title is tab 1; the unknown name is tab 2, shared by every use
		end
		title = '${1:Take care of your golden goose}'
		desc_n = name_lit ? 2 : 3
		lines = []
		lines << "#' #{title}"
		lines << "#'"
		lines << "#' @description"
		lines << "#' \\`#{name_bits[0]}\\` #{takes_phrase(header.args)} ${#{desc_n}:}"
		lines << "#'"
		lines << "#' @details"
		lines << "#'"
		tab = desc_n
		names = []
		header.args.each do |arg|
			tab += 1
			names << arg.name
			lines << "#' @param #{snippet_literal(arg.name)} ${#{tab}:#{placeholder(arg)}}"
		end
		call = names.empty? ? '' : names.map { |a| snippet_literal(a) }.join(', ')
		lines << "#' @return - [#{name_bits[0]}()]"
		lines << "#' @export"
		lines << "#' @family"
		tab += 1
		see = tab
		tab += 1
		ref = tab
		tab += 1
		url = tab
		lines << "#' @seealso - [${#{see}:umxLabel}()]"
		lines << "#' @references - [${#{ref}:tutorials}](https://tbates.github.io), [${#{ref}:github}](${#{url}:https://github.com/tbates/umx})"
		lines << "#' @md"
		lines << "#' @examples"
		lines << "#' #{name_bits[0]}(#{call})"
		lines << "#' \\dontrun{"
		lines << "#' "
		lines << "#' }"
		stub = lines.join("\n") + "\n"
		stub + snippet_literal(header.raw)
	end

	def index_of_function(src)
		i = 0
		depth = 0
		while i < src.length
			c = src[i]
			if c == '#'
				i = eol(src, i)
				next
			end
			if c == '"' || c == "'"
				i = skip_string(src, i)
				next
			end
			if c == '(' || c == '[' || c == '{'
				depth += 1
				i += 1
				next
			end
			if c == ')' || c == ']' || c == '}'
				depth -= 1 if depth > 0
				i += 1
				next
			end
			if depth == 0 && src[i, 8] == 'function' && boundary_before(src, i) && boundary_after(src, i + 8)
				return i
			end
			i += 1
		end
		nil
	end

	def name_before(src, fn)
		head = src[0...fn]
		m = head.match(/(?:(`[^`\n]+`)|("(?:\\.|[^"\\\n])*")|('(?:\\.|[^'\\\n])*')|((?:[\p{L}_.][\w.]*)(?:::[\p{L}_.][\w.]*)?))\s*(?:<<-|<-|=)\s*\z/)
		return nil unless m
		m[1] || m[2] || m[3] || m[4]
	end

	def display_name(token)
		return token[1..-2] if token.start_with?('"') || token.start_with?("'")
		token
	end

	def split_args(inner)
		args = []
		buf = +''
		i = 0
		depth = 0
		while i < inner.length
			c = inner[i]
			if c == '#'
				i = eol(inner, i)
				next
			end
			if c == '"' || c == "'"
				j = skip_string(inner, i)
				buf << inner[i...j]
				i = j
				next
			end
			if c == '(' || c == '[' || c == '{'
				depth += 1
				buf << c
				i += 1
				next
			end
			if c == ')' || c == ']' || c == '}'
				depth -= 1 if depth > 0
				buf << c
				i += 1
				next
			end
			if c == ',' && depth == 0
				push_arg(args, buf)
				buf = +''
				i += 1
				next
			end
			buf << c
			i += 1
		end
		push_arg(args, buf)
		args
	end

	def push_arg(args, buf)
		text = buf.strip
		return if text.empty?
		if text == '...'
			args << Arg.new('...', nil)
			return
		end
		name, default = split_default(text)
		return if name.nil? || name.empty?
		args << Arg.new(name, default)
	end

	def split_default(text)
		i = 0
		depth = 0
		while i < text.length
			c = text[i]
			if c == '#'
				break
			end
			if c == '"' || c == "'"
				i = skip_string(text, i)
				next
			end
			if c == '(' || c == '[' || c == '{'
				depth += 1
			elsif c == ')' || c == ']' || c == '}'
				depth -= 1 if depth > 0
			elsif c == '=' && depth == 0
				return [text[0...i].strip, text[(i + 1)..-1].strip]
			end
			i += 1
		end
		[text.strip, nil]
	end

	def match_closer(src, open_at)
		i = open_at + 1
		depth = 1
		while i < src.length
			c = src[i]
			if c == '#'
				i = eol(src, i)
				next
			end
			if c == '"' || c == "'"
				i = skip_string(src, i)
				next
			end
			if c == '('
				depth += 1
			elsif c == ')'
				depth -= 1
				return i if depth == 0
			end
			i += 1
		end
		nil
	end

	def skip_string(src, i)
		q = src[i]
		i += 1
		while i < src.length
			c = src[i]
			if c == '\\'
				i += 2
				next
			end
			return i + 1 if c == q
			break if c == "\n"
			i += 1
		end
		i
	end

	def eol(src, i)
		j = src.index("\n", i)
		j ? j + 1 : src.length
	end

	def index_after_ws(src, i)
		i += 1 while i < src.length && src[i] =~ /[ \t\r\n]/
		i < src.length ? i : nil
	end

	def boundary_before(src, i)
		i == 0 || src[i - 1] !~ /[\w.]/
	end

	def boundary_after(src, i)
		i >= src.length || src[i] !~ /[\w.]/
	end

	def takes_phrase(args)
		shown = args.map { |a| snippet_literal(a.name) }
		case shown.length
		when 0
			'to return a'
		when 1
			"takes a #{shown[0]} to return a"
		when 2
			"takes a #{shown[0]} and #{shown[1]} to return a"
		else
			"takes a #{shown[0..-2].join(', ')}, and #{shown[-1]} to return a"
		end
	end

	def placeholder(arg)
		return '' unless arg.default && !arg.default.empty?
		inner = arg.default.gsub(/[\\$`|}]/) { |c| "\\#{c}" }
		"Default \\`#{inner}\\`."
	end

	def snippet_literal(text)
		text.to_s.gsub(/[\\$`]/) { |c| "\\#{c}" }
	end
end
