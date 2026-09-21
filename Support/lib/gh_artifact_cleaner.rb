#!/usr/bin/env ruby -wEutf-8
# gh delete artifacts from selected repo: summarize live Actions artifacts
# for one repo and, on confirmation, delete them.
#
# Input: TM_SELECTED_TEXT, else TM_CURRENT_WORD, else ARGV[0] (so plain
# `ruby gh_artifact_cleaner.rb user/repo` works in Terminal).
# `--dry-run` prints the exact dialog message without showing the dialog.
# Verify: ruby gh_artifact_cleaner.rb --dry-run tbates/textmate

require "json"
require "open3"

["/opt/homebrew/bin", "/usr/local/bin"].each do |d|
  ENV["PATH"] = "#{d}:#{ENV["PATH"]}" unless ENV["PATH"].split(":").include?(d)
end

REPO_RE = %r{\A[\w.\-]+/[\w.\-]+\z}.freeze

def mb(bytes)
  format("%.1f MB", bytes / 1048576.0)
end

def repo_from_env
  sel = ENV["TM_SELECTED_TEXT"].to_s.strip
  return sel unless sel.empty?
  word = ENV["TM_CURRENT_WORD"].to_s.strip
  return word unless word.empty?
  ARGV.reject { |a| a.start_with?("-") }.first.to_s.strip
end

def abort_usage(got)
  abort("Select a repo as user/repo (got: #{got.inspect}).")
end

def gh(*args)
  out, status = Open3.capture2e("gh", *args)
  abort("gh failed: #{out.strip}") unless status.success?
  out
end

def live_artifacts(repo)
  out = gh("api", "repos/#{repo}/actions/artifacts", "--paginate",
    "--jq", '.artifacts[] | select(.expired == false) | "\(.id) \(.size_in_bytes) \(.workflow_run.id)"')
  out.lines.map do |line|
    id_s, bytes_s, run_s = line.split
    { :id => id_s, :bytes => bytes_s.to_i, :run => run_s }
  end
end

def summary(repo, arts)
  total = arts.inject(0) { |s, a| s + a[:bytes] }
  by_run = arts.group_by { |a| a[:run] }
  lines = ["#{repo}: #{arts.size} artifact#{arts.size == 1 ? "" : "s"}, #{mb(total)} across #{by_run.size} build#{by_run.size == 1 ? "" : "s"}"]
  by_run.sort_by { |_, v| -v.inject(0) { |s, a| s + a[:bytes] } }.first(20).each do |run, v|
    bytes = v.inject(0) { |s, a| s + a[:bytes] }
    lines << "  run #{run}: #{v.size} artifact#{v.size == 1 ? "" : "s"}, #{mb(bytes)}"
  end
  lines << "  …and #{by_run.size - 20} more builds" if by_run.size > 20
  [lines.join("\n"), total]
end

def ask(message)
  esc = message.gsub("\\", "\\\\").gsub('"', '\\"')
  dialog = "display dialog \"#{esc}\" buttons {\"Cancel\", \"Browse\", \"Delete\"} " \
    "default button \"Cancel\" with title \"gh delete artifacts\""
  out, status = Open3.capture2e("osascript",
    "-e", 'tell application "TextMate" to activate', "-e", dialog)
  return :cancel unless status.success?
  m = out.match(/button returned:(\w+)/)
  m ? m[1].downcase.to_sym : :cancel
end

repo = repo_from_env
abort_usage(repo) unless repo =~ REPO_RE

arts = live_artifacts(repo)
if arts.empty?
  puts "#{repo}: no live artifacts."
  exit 0
end
text, _total = summary(repo, arts)

if ARGV.include?("--dry-run")
  puts text + "\nDelete all #{arts.size}?"
  exit 0
end

case ask(text + "\nDelete all #{arts.size}?")
when :browse
  system("open", "https://github.com/#{repo}/actions")
  exit 0
when :delete
  freed = 0
  arts.each do |a|
    _out, status = Open3.capture2e("gh", "api", "--method", "DELETE",
      "repos/#{repo}/actions/artifacts/#{a[:id]}")
    freed += a[:bytes] if status.success?
  end
  system("open", "https://github.com/#{repo}/actions")
  puts "Deleted #{arts.size} artifacts, freed #{mb(freed)}."
else
  exit 0
end
