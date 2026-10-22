#!/usr/bin/env ruby -wEutf-8
# Inventory the colors in a TextMate .tmTheme.
#
# A near-gray is a color whose red, green, and blue channels are equal,
# or at most one apart (0..255). Those are listed light to dark. Every
# other color is listed by hue. Each row is the hex, a swatch, and the
# scope rules (or global / gutter settings) that use it.

require 'json'

module ThemeColors
	Use = Struct.new(:role, :where, :scope, :font_style)

	module_function

	# The open document when it is a theme; otherwise the theme TextMate
	# is currently drawing with (TM_CURRENT_THEME_PATH).
	def theme_path
		file = ENV['TM_FILEPATH']
		if file && File.file?(file) && File.extname(file).casecmp('.tmTheme').zero?
			return file
		end
		current = ENV['TM_CURRENT_THEME_PATH']
		return current if current && File.file?(current)
		raise 'No theme. Open a .tmTheme, or run this from TextMate so the current theme is available.'
	end

	def show
		puts page_for(theme_path)
	rescue => e
		puts error_page(e.message)
	end

	def page_for(path)
		doc = read_theme(path)
		html(inventory(doc, path))
	end

	def read_theme(path)
		raise "Not a file: #{path}" unless File.file?(path)
		json = IO.popen(['plutil', '-convert', 'json', '-o', '-', path], &:read)
		raise "Could not read #{path} as a property list." unless $?.success?
		JSON.parse(json)
	end

	# #RGB, #RGBA, #RRGGBB, #RRGGBBAA. Returns lowercase #rrggbb or #rrggbbaa.
	def normalize(raw)
		return nil unless raw.is_a?(String)
		s = raw.strip
		return nil unless s =~ /\A#([0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\z/
		body = $1
		body = body.chars.map { |c| c * 2 }.join if body.length <= 4
		'#' + body.downcase
	end

	# [r, g, b] in 0..255, and alpha in 0..255 (255 when the hex has no alpha).
	def channels(hex)
		body = hex[1..-1]
		rgb = [body[0, 2], body[2, 2], body[4, 2]].map { |pair| pair.to_i(16) }
		alpha = body.length == 8 ? body[6, 2].to_i(16) : 255
		[rgb, alpha]
	end

	def near_gray?(hex)
		rgb, = channels(hex)
		rgb.max - rgb.min <= 1
	end

	def luma(hex)
		r, g, b = channels(hex)[0]
		0.2126 * r + 0.7152 * g + 0.0722 * b
	end

	# Hue wheel, cut at the widest gap so reds and pinks stay in one run
	# instead of pink wrapping past purple to the other end of the list.
	def order_by_hue(hexes)
		keyed = hexes.sort_by { |hex| hue_key(hex) + [hex] }
		return keyed if keyed.length < 3
		hues = keyed.map { |hex| hue_key(hex)[0] }
		biggest = hues[0] + 360 - hues[-1]
		gap_at = 0
		hues.each_cons(2).with_index do |(a, b), i|
			gap = b - a
			if gap > biggest
				biggest = gap
				gap_at = i + 1
			end
		end
		keyed.rotate(gap_at)
	end

	# Hue in degrees, then lightness, so neighboring swatches are neighbors.
	def hue_key(hex)
		r, g, b = channels(hex)[0].map { |c| c / 255.0 }
		mx = [r, g, b].max
		mn = [r, g, b].min
		light = (mx + mn) / 2.0
		if mx == mn
			hue = 0.0
		else
			d = mx - mn
			hue = if mx == r
				((g - b) / d) % 6
			elsif mx == g
				(b - r) / d + 2
			else
				(r - g) / d + 4
			end
			hue *= 60
		end
		[hue, -light]
	end

	def inventory(doc, path)
		uses = Hash.new { |h, k| h[k] = [] }
		colorless = []

		gutter = doc['gutterSettings']
		if gutter.is_a?(Hash)
			gutter.each do |key, value|
				hex = normalize(value)
				next unless hex
				uses[hex] << Use.new(key.to_s, 'Gutter', nil, nil)
			end
		end

		Array(doc['settings']).each do |rule|
			next unless rule.is_a?(Hash)
			inner = rule['settings']
			next unless inner.is_a?(Hash)
			name = rule['name']
			scope = rule['scope']
			where = if name.nil? && scope.nil?
				'Global'
			else
				(name || scope).to_s
			end
			font = inner['fontStyle']
			font = font.to_s if font
			found = false
			inner.each do |key, value|
				hex = normalize(value)
				next unless hex
				found = true
				uses[hex] << Use.new(key.to_s, where, scope && scope.to_s, font)
			end
			if !found && font && !font.empty?
				colorless << { :where => where, :scope => scope && scope.to_s, :font_style => font }
			end
		end

		uses.each_value do |list|
			list.sort_by! { |u| [u.role, u.where.to_s, u.scope.to_s] }
		end

		grays, colors = uses.keys.partition { |hex| near_gray?(hex) }
		grays.sort_by! { |hex| [-luma(hex), -channels(hex)[1], hex] }
		colors = order_by_hue(colors)

		{
			:name => (doc['name'] || File.basename(path, '.tmTheme')).to_s,
			:author => doc['author'] && doc['author'].to_s,
			:semantic_class => doc['semanticClass'] && doc['semanticClass'].to_s,
			:path => path.to_s,
			:uses => uses,
			:grays => grays,
			:colors => colors,
			:colorless => colorless,
		}
	end

	def html(inv)
		grays = section('Near-grays, light to dark', 'Red, green, and blue equal, or one channel off by 1.', inv[:grays], inv[:uses])
		colors = section('Other colors, by hue', 'Same hex is one row, however many scopes share it.', inv[:colors], inv[:uses])
		plain = colorless_section(inv[:colorless])
		n = inv[:grays].length + inv[:colors].length
		meta = [inv[:author], inv[:semantic_class]].compact.reject(&:empty?)
		<<~HTML
			<!DOCTYPE html>
			<html>
			<head>
			<meta charset="utf-8">
			<title>#{h inv[:name]} colors</title>
			<style>
				body { font: 14px/1.35 -apple-system, BlinkMacSystemFont, sans-serif; color: #1c1c1c; background: #f6f6f4; margin: 24px; }
				h1 { font-size: 22px; font-weight: 650; margin: 0 0 4px; }
				.meta, .path, .lead { color: #555; margin: 0 0 4px; }
				.path { font-family: ui-monospace, Menlo, monospace; font-size: 12px; }
				.cols { display: flex; gap: 36px; align-items: flex-start; margin-top: 18px; }
				section { flex: 1; min-width: 320px; }
				h2 { font-size: 15px; margin: 0 0 2px; }
				.note { color: #666; font-size: 12px; margin: 0 0 12px; }
				.row { display: flex; gap: 10px; align-items: flex-start; margin: 0 0 12px; cursor: pointer; }
				.row.copied .hex { color: #0a7a32; }
				.swatch {
					width: 44px; height: 22px; flex: none; margin-top: 1px;
					border-radius: 4px; border: 1px solid rgba(0,0,0,.28);
					background-color: #fff;
					background-image:
						linear-gradient(var(--c), var(--c)),
						linear-gradient(45deg, #c8c8c8 25%, transparent 25%),
						linear-gradient(-45deg, #c8c8c8 25%, transparent 25%),
						linear-gradient(45deg, transparent 75%, #c8c8c8 75%),
						linear-gradient(-45deg, transparent 75%, #c8c8c8 75%);
					background-size: auto, 8px 8px, 8px 8px, 8px 8px, 8px 8px;
					background-position: 0 0, 0 0, 0 4px, 4px -4px, -4px 0;
				}
				.hex { font-family: ui-monospace, Menlo, monospace; font-weight: 650; }
				.alpha { color: #666; font-weight: 400; font-size: 12px; }
				.uses { margin: 2px 0 0; padding: 0; list-style: none; color: #333; font-size: 13px; }
				.uses li { margin: 0; }
				.plain { margin: 18px 0 0; color: #333; }
				.plain h2 { margin-bottom: 6px; }
				.plain li { margin: 0 0 2px; }
			</style>
			</head>
			<body>
			<h1>#{h inv[:name]}</h1>
			<p class="meta">#{h(meta.join(' · '))}#{meta.empty? ? '' : ' · '}#{n} colors · #{inv[:grays].length} near-gray · #{inv[:colors].length} chromatic</p>
			<p class="path">#{h inv[:path]}</p>
			<p class="lead">Click a row to copy the hex.</p>
			<div class="cols">
			#{grays}
			#{colors}
			</div>
			#{plain}
			<script>
			document.querySelectorAll('[data-hex]').forEach(function (row) {
				row.addEventListener('click', function () {
					var hex = row.getAttribute('data-hex');
					var done = function () {
						row.classList.add('copied');
						setTimeout(function () { row.classList.remove('copied'); }, 700);
					};
					if (navigator.clipboard && navigator.clipboard.writeText) {
						navigator.clipboard.writeText(hex).then(done);
					} else {
						done();
					}
				});
			});
			</script>
			</body>
			</html>
		HTML
	end

	def section(title, note, hexes, uses)
		rows = hexes.map { |hex| row(hex, uses[hex]) }.join("\n")
		rows = '<p class="note">None.</p>' if hexes.empty?
		<<~HTML
			<section>
			<h2>#{h title}</h2>
			<p class="note">#{h note}</p>
			#{rows}
			</section>
		HTML
	end

	def row(hex, uses)
		_rgb, alpha = channels(hex)
		alpha_note = alpha == 255 ? '' : %(<span class="alpha"> · #{(100.0 * alpha / 255).round}% opaque</span>)
		items = uses.map { |use| "<li>#{h use_label(use)}</li>" }.join
		%(<div class="row" data-hex="#{h hex}"><div class="swatch" style="--c: #{css_color(hex)}"></div><div><div class="hex">#{h hex}#{alpha_note}</div><ul class="uses">#{items}</ul></div></div>)
	end

	def use_label(use)
		bits = [use.role, use.where]
		bits << use.scope if use.scope && use.scope != use.where
		bits << use.font_style if use.font_style && !use.font_style.empty?
		bits.join(' · ')
	end

	def colorless_section(rules)
		return '' if rules.empty?
		items = rules.map { |rule|
			label = rule[:where].dup
			label << " · #{rule[:scope]}" if rule[:scope] && rule[:scope] != rule[:where]
			label << " · #{rule[:font_style]}"
			"<li>#{h label}</li>"
		}.join
		%(<div class="plain"><h2>Rules with no color</h2><ul>#{items}</ul></div>)
	end

	def css_color(hex)
		rgb, alpha = channels(hex)
		if alpha == 255
			hex
		else
			format('rgba(%d, %d, %d, %.3f)', rgb[0], rgb[1], rgb[2], alpha / 255.0)
		end
	end

	def error_page(message)
		<<~HTML
			<!DOCTYPE html>
			<html><head><meta charset="utf-8"><title>Show theme colors</title></head>
			<body style="font: 14px -apple-system, sans-serif">
			<h1>Show theme colors</h1>
			<p>#{h message}</p>
			</body></html>
		HTML
	end

	def h(text)
		text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
	end
end

if $0 == __FILE__
	path = ARGV[0] || ThemeColors.theme_path
	puts ThemeColors.page_for(path)
end
