#!/usr/bin/env ruby -wEutf-8
require_relative 'muse_open_session'
require 'tmpdir'
require 'fileutils'

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

def direct(payload)
	{ 'schema_version' => 1, 'payload_type' => 'runtime.session', 'payload' => payload }
end

def write_log(dir, records)
	path = File.join(dir, 'session.jsonl')
	File.open(path, 'w') { |f| records.each { |r| f.puts(JSON.generate(r)) } }
	path
end

Dir.mktmpdir do |tmp|
	ws = File.join(tmp, 'ws')
	FileUtils.mkdir_p(ws)

	log = write_log(tmp, [
		{ 'retained_frame' => 'x', 'children' => [
			{ 'record_json' => JSON.generate(direct({ 'kind' => 'metadata', 'record' => { 'workspace_root' => ws } })) }
		] },
		direct({ 'kind' => 'run', 'event' => { 'kind' => 'started', 'prompt' => 'first prompt here' } }),
		direct({ 'kind' => 'run', 'event' => { 'kind' => 'assistant_message_committed', 'text' => 'hi' } }),
		direct({ 'kind' => 'run', 'event' => { 'kind' => 'started', 'prompt' => "second  prompt\nwith newline" } }),
		'not json at all'
	])

	check('parse_log reads workspace from wrapped child record') do
		assert_equal(ws, MuseSessions.parse_log(log)[:workspace])
	end

	check('parse_log keeps last started prompt, collapsed') do
		assert_equal('second prompt with newline', MuseSessions.parse_log(log)[:last_prompt])
	end

	check('parse_log tolerates missing file') do
		assert_equal({ workspace: nil, last_prompt: '' }, MuseSessions.parse_log(File.join(tmp, 'nope.jsonl')))
	end

	check('applescript_escape doubles backslash and quote') do
		assert_equal('a\\\\b\\"c', MuseSessions.applescript_escape('a\b"c'))
	end

	mk = lambda do |id, workspace, prompt|
		{ id: id, mtime: Time.local(2026, 10, 27, 20, 0, 0), workspace: workspace, last_prompt: prompt }
	end

	check('display_rows flags workspace gone from disk') do
		rows = MuseSessions.display_rows([mk.call('aaaabbbb-1', File.join(tmp, 'gone-dir'), 'hello')])
		raise "no gone flag: #{rows[0][0]}" unless rows[0][0].include?('[gone]')
	end

	check('display_rows widens basename on collision') do
		s1 = mk.call('aaaabbbb-1', File.join(tmp, 'projA', 'shared'), 'one')
		s2 = mk.call('ccccdddd-2', File.join(tmp, 'projB', 'shared'), 'two')
		rows = MuseSessions.display_rows([s1, s2])
		raise "not disambiguated: #{rows.map(&:first).inspect}" unless rows[0][0].include?('projA/shared') && rows[1][0].include?('projB/shared')
	end

	check('display_rows dedupes identical rows') do
		s = mk.call('aaaabbbb-1', ws, 'same')
		rows = MuseSessions.display_rows([s, s.dup])
		assert_equal(2, rows.map(&:first).uniq.length)
	end

	check('display_rows shows placeholder with no prompts') do
		rows = MuseSessions.display_rows([mk.call('aaaabbbb-1', ws, '')])
		raise "no placeholder: #{rows[0][0]}" unless rows[0][0].include?('(no prompts yet)')
	end

	check('recent defaults to 20 sessions') do
		home = File.join(tmp, 'fakehome')
		25.times do |i|
			d = File.join(home, '.local', 'share', 'muse', 'sessions', '2026', '10', '27', format('id-%02d', i))
			FileUtils.mkdir_p(d)
			File.write(File.join(d, 'session.jsonl'), '')
		end
		old_xdg = ENV['XDG_DATA_HOME']
		begin
			ENV['XDG_DATA_HOME'] = File.join(home, '.local', 'share')
			assert_equal(20, MuseSessions.recent.length)
		ensure
			old_xdg.nil? ? ENV.delete('XDG_DATA_HOME') : ENV['XDG_DATA_HOME'] = old_xdg
		end
	end

	check('valid_id? accepts UUIDs, rejects junk') do
		assert_equal(true, MuseSessions.valid_id?('aaaaaaaa-1111-2222-3333-444444444444'))
		assert_equal(false, MuseSessions.valid_id?('01a17c4d'))
		assert_equal(false, MuseSessions.valid_id?('../../../etc'))
		assert_equal(false, MuseSessions.valid_id?(nil))
		assert_equal(:refused, MuseSessions.delete_session('junk'))
	end

	check('delete_session removes unlocked session tree') do
		base = File.join(tmp, 'delhome', '.local', 'share')
		id = 'aaaaaaaa-1111-2222-3333-444444444444'
		d = File.join(base, 'muse', 'sessions', '2026', '10', '27', id)
		FileUtils.mkdir_p(File.join(d, 'subagent', 'x'))
		File.write(File.join(d, 'session.jsonl'), "{}\n")
		old_xdg = ENV['XDG_DATA_HOME']
		begin
			ENV['XDG_DATA_HOME'] = base
			assert_equal(d, MuseSessions.session_dir(id))
			assert_equal(false, MuseSessions.lock_live?(d))
			assert_equal(:deleted, MuseSessions.delete_session(id))
			raise 'tree still on disk' if File.exist?(d)
			assert_equal(:refused, MuseSessions.delete_session(id))
		ensure
			old_xdg.nil? ? ENV.delete('XDG_DATA_HOME') : ENV['XDG_DATA_HOME'] = old_xdg
		end
	end

	check('delete_session spares lock-held session') do
		base = File.join(tmp, 'lockhome', '.local', 'share')
		id = 'bbbbbbbb-1111-2222-3333-444444444444'
		d = File.join(base, 'muse', 'sessions', '2026', '10', '27', id)
		FileUtils.mkdir_p(d)
		lock = File.join(d, '.session.lock')
		File.write(lock, 'pid')
		old_xdg = ENV['XDG_DATA_HOME']
		begin
			ENV['XDG_DATA_HOME'] = base
			File.open(lock, 'r') do |f|
				f.flock(File::LOCK_EX)
				assert_equal(true, MuseSessions.lock_live?(d))
				assert_equal(:live, MuseSessions.delete_session(id))
			end
			raise 'tree removed despite live lock' unless Dir.exist?(d)
			assert_equal(false, MuseSessions.lock_live?(d))
		ensure
			old_xdg.nil? ? ENV.delete('XDG_DATA_HOME') : ENV['XDG_DATA_HOME'] = old_xdg
		end
	end

	check('delete_picker_script allows multiple selection with linefeed join') do
		src = MuseSessions.delete_picker_script([['row one', 'id1']])
		raise 'no multi-select' unless src.include?('multiple selections allowed')
		raise 'no linefeed join' unless src.include?('delimiters to linefeed')
	end
end

if $failures.zero?
	puts 'PASS muse_open_session'
else
	puts "#{$failures} FAILURES"
	exit 1
end
