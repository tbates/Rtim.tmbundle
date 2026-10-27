#!/usr/bin/env ruby
# encoding: utf-8
#
# Open Muse Session: list Muse Code sessions across ALL workspaces
# (bare `muse resume` only seeds its picker with the current workspace),
# pick one from a dialog, resume it in Terminal.app.
# Top picker row opens delete mode: multi-select sessions, confirm once,
# remove them from disk. Live (lock-held) sessions are never deleted.
#
# Run from TextMate via the thin .tmCommand launcher.
# Headless: --list (print rows), --script (print picker AppleScript),
# --delete-script (print delete-picker AppleScript),
# --confirm-sample (print sample confirm dialog AppleScript),
# --resume-script (print resume AppleScript for newest session).

require 'json'
require 'shellwords'
require 'fileutils'

module MuseSessions
  LIMIT = 20
  DELETE_ROW = '[ Delete sessions… ]'

  module_function

  def sessions_root
    base = ENV['XDG_DATA_HOME']
    base = File.expand_path('~/.local/share') if base.nil? || base.empty?
    File.join(base, 'muse', 'sessions')
  end

  # Parse one session.jsonl. Line 1 is usually a wrapped transaction whose
  # real records live in children[].record_json; the rest are direct
  # envelopes. Returns {workspace:, last_prompt:}.
  def parse_log(path)
    workspace = nil
    last_prompt = ''
    File.foreach(path, encoding: 'utf-8') do |line|
      line = line.strip
      next if line.empty?
      outer = (JSON.parse(line) rescue nil)
      next unless outer.is_a?(Hash)
      records = []
      if outer['children'].is_a?(Array)
        outer['children'].each do |child|
          raw = child.is_a?(Hash) ? child['record_json'] : nil
          next unless raw.is_a?(String)
          rec = (JSON.parse(raw) rescue nil)
          records << rec if rec.is_a?(Hash)
        end
      elsif outer['payload'].is_a?(Hash)
        records << outer
      end
      records.each do |rec|
        payload = rec['payload'] || {}
        if payload['kind'] == 'metadata' && workspace.nil?
          workspace = (payload['record'] || {})['workspace_root']
        end
        event = payload['event'] || {}
        if event['kind'] == 'started' && event['prompt'].is_a?(String) && !event['prompt'].empty?
          last_prompt = event['prompt']
        end
      end
    end
    { workspace: workspace, last_prompt: collapse(last_prompt) }
  rescue SystemCallError
    { workspace: nil, last_prompt: '' }
  end

  def collapse(text)
    text.gsub(/[[:cntrl:]]/, ' ').gsub(/\s+/, ' ').strip
  end

  def recent(limit = LIMIT)
    pattern = File.join(sessions_root, '*', '*', '*', '*', 'session.jsonl')
    paths = Dir[pattern].select { |p| File.file?(p) }
    paths = paths.sort_by { |p| File.mtime(p) }.reverse.first(limit)
    paths.map do |path|
      parsed = parse_log(path)
      {
        id: File.basename(File.dirname(path)),
        mtime: File.mtime(path),
        workspace: parsed[:workspace],
        last_prompt: parsed[:last_prompt]
      }
    end
  end

  # Short workspace label: basename, widened to last two path components on
  # collision, flagged when missing or gone from disk.
  def workspace_label(workspace, others)
    return '?' if workspace.nil? || workspace.empty?
    base = File.basename(workspace)
    if others.any? { |o| o != workspace && !o.to_s.empty? && File.basename(o) == base }
      base = File.join(File.basename(File.dirname(workspace)), base)
    end
    base += ' [gone]' unless Dir.exist?(workspace)
    base
  end

  # Returns array of [display_string, session_id] with unique display strings.
  def display_rows(sessions)
    workspaces = sessions.map { |s| s[:workspace] }
    seen = Hash.new(0)
    sessions.map do |s|
      label = workspace_label(s[:workspace], workspaces)
      prompt = s[:last_prompt].empty? ? '(no prompts yet)' : s[:last_prompt][0, 90]
      row = format('%s | %s | %s | %s', s[:mtime].strftime('%m-%d %H:%M'), s[:id][0, 8], label, prompt)
      seen[row] += 1
      row += " (#{seen[row]})" if seen[row] > 1
      [row, s[:id]]
    end
  end

  def applescript_escape(text)
    text.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }
  end

  def picker_script(rows)
    list = rows.map { |row, _| %("#{applescript_escape(row)}") }.join(', ')
    %Q{choose from list {#{list}} with prompt "Resume Muse session (newest first):" with title "Muse Sessions"}
  end

  def delete_picker_script(rows)
    list = rows.map { |row, _| %("#{applescript_escape(row)}") }.join(', ')
    [
      %Q{set picks to choose from list {#{list}} with prompt "Delete sessions (no undo, Cmd-click for several):" with title "Muse Sessions" with multiple selections allowed},
      'if picks is false then return ""',
      %Q{set AppleScript's text item delimiters to linefeed},
      'return picks as string'
    ].join("\n")
  end

  def confirm_script(message)
    title, _, body = message.partition("\n")
    %Q{display alert "#{applescript_escape(title)}" message "#{applescript_escape(body.strip)}" buttons {"Delete", "Cancel"} default button "Cancel" cancel button "Cancel" as critical}
  end

  def notice_script(message)
    %Q{display dialog "#{applescript_escape(message)}" buttons {"OK"} default button "OK"}
  end

  def resume_script(muse_bin, session_id)
    shell = "#{Shellwords.escape(muse_bin)} resume #{Shellwords.escape(session_id)}"
    %Q{tell application "Terminal" to do script "#{applescript_escape(shell)}"}
  end

  def find_muse
    cands = [File.expand_path('~/.local/bin/muse'), '/opt/homebrew/bin/muse',
             '/usr/local/bin/muse', '/usr/bin/muse']
    (ENV['PATH'] || '').split(':').each { |d| cands << File.join(d, 'muse') }
    cands.find { |p| File.file?(p) && File.executable?(p) }
  end

  def osascript(source)
    out = IO.popen(['osascript', '-e', source], &:read).to_s.strip
    @last_status = $?.nil? ? 1 : $?.exitstatus
    out
  end

  def last_status
    @last_status
  end

  def alert(title, message)
    osascript(%Q{display alert "#{applescript_escape(title)}" message "#{applescript_escape(message)}" as critical})
  end

  def notice(message)
    osascript(notice_script(message))
  end

  def confirmed?(message)
    out = osascript(confirm_script(message))
    last_status == 0 && out == 'button returned:Delete'
  end

  def valid_id?(id)
    id.is_a?(String) && !!(id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  # Locate a session dir by id. Glob-based so the result always sits under
  # sessions_root; nil when the id is malformed or unknown.
  def session_dir(id)
    return nil unless valid_id?(id)
    Dir[File.join(sessions_root, '*', '*', '*', id)].find { |d| File.directory?(d) }
  end

  # True when another process holds the session lock. Missing lock file or
  # read errors count as not live.
  def lock_live?(dir)
    lock = File.join(dir, '.session.lock')
    return false unless File.file?(lock)
    File.open(lock, 'r') do |f|
      return f.flock(File::LOCK_EX | File::LOCK_NB) != 0
    end
  rescue SystemCallError
    false
  end

  def delete_session(id)
    dir = session_dir(id)
    return :refused if dir.nil? || File.symlink?(dir)
    return :live if lock_live?(dir)
    FileUtils.rm_rf(dir)
    :deleted
  end

  def run_delete(sessions)
    rows = display_rows(sessions)
    choice = osascript(delete_picker_script(rows))
    return 0 if choice.empty?
    by_row = rows.to_h
    ids = choice.split("\n").map { |line| by_row[line] }.compact.uniq
    return 0 if ids.empty?
    by_id = rows.map { |row, id| [id, row] }.to_h
    shown = ids.first(10).map { |id| by_id[id] }
    shown << "…and #{ids.length - 10} more." if ids.length > 10
    plural = ids.length == 1 ? '' : 's'
    return 0 unless confirmed?("Delete #{ids.length} session#{plural}? No undo.\n\n#{shown.join("\n")}")
    results = ids.map { |id| delete_session(id) }
    deleted = results.count(:deleted)
    live = results.count(:live)
    refused = results.count(:refused)
    parts = ["Deleted #{deleted} session#{deleted == 1 ? '' : 's'}."]
    parts << "Skipped #{live} live (still open)." if live > 0
    parts << "Skipped #{refused} (already gone)." if refused > 0
    notice(parts.join(' '))
    0
  end

  def run
    sessions = recent
    if sessions.empty?
      notice("No Muse sessions found under #{sessions_root}.")
      return 0
    end
    rows = display_rows(sessions)
    choice = osascript(picker_script([[DELETE_ROW, nil]] + rows))
    return 0 if choice.empty? || choice == 'false'
    return run_delete(sessions) if choice == DELETE_ROW
    id = rows.to_h[choice]
    return 0 if id.nil?
    muse = find_muse
    if muse.nil?
      alert('muse binary not found', 'Install the Muse CLI or symlink it into ~/.local/bin, then retry.')
      return 1
    end
    system('osascript', '-e', resume_script(muse, id)) ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV[0]
  when '--list'
    MuseSessions.display_rows(MuseSessions.recent).each { |row, _| puts row }
  when '--script'
    puts MuseSessions.picker_script(MuseSessions.display_rows(MuseSessions.recent))
  when '--delete-script'
    puts MuseSessions.delete_picker_script(MuseSessions.display_rows(MuseSessions.recent))
  when '--confirm-sample'
    puts MuseSessions.confirm_script("Delete 2 sessions? No undo.\n\nrow one\nrow two")
  when '--resume-script'
    first = MuseSessions.recent(1).first
    if first
      muse = MuseSessions.find_muse || 'muse'
      puts MuseSessions.resume_script(muse, first[:id])
    end
  else
    exit(MuseSessions.run)
  end
end
