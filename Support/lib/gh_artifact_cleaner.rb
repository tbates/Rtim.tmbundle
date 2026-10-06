#!/usr/bin/env ruby -wEutf-8
# gh delete artifacts from repo.
#
# The repo is the GitHub origin of the file's git checkout. A user/repo
# argument still works from the terminal. The word under the caret is ignored.
#
# The dialog asks what to delete (failed runs, all runs, or all but the two
# most recent) and whether to remove only artifacts or the runs as well.
# Deleting a run removes its log and its artifacts.
#
#   ruby gh_artifact_cleaner.rb --dry-run --what failed --only-artifacts
#   ruby gh_artifact_cleaner.rb --dry-run --what keep2 --runs tbates/umx
# --what is failed, all, or keep2.

require "json"
require "open3"

["/opt/homebrew/bin", "/usr/local/bin"].each do |d|
  ENV["PATH"] = "#{d}:#{ENV["PATH"]}" unless ENV["PATH"].split(":").include?(d)
end

REPO_RE = %r{\A[\w.\-]+/[\w.\-]+\z}.freeze
WHAT = { "failed" => :failed, "all" => :all, "keep2" => :keep2 }.freeze
WHAT_LABEL = {
  :failed => "failed runs",
  :all => "all completed runs",
  :keep2 => "all but the 2 most recent runs",
}.freeze

def mb(bytes)
  format("%.1f MB", bytes / 1048576.0)
end

def abort_usage(msg)
  abort(msg)
end

def github_slug(url)
  u = url.to_s.strip.sub(/\.git\z/, "")
  return $1 if u =~ %r{\Agit@github\.com:([^/]+/[^/]+)\z}
  return $1 if u =~ %r{\Ahttps?://github\.com/([^/]+/[^/]+)\z}
  return $1 if u =~ %r{\Assh://git@github\.com/([^/]+/[^/]+)\z}
  nil
end

def existing_dir(path)
  return path if path && File.directory?(path)
  nil
end

def repo_from_git
  file = ENV["TM_FILEPATH"]
  dir = File.dirname(file) if file && !file.empty? && File.exist?(file)
  dir = existing_dir(dir) || existing_dir(ENV["TM_DIRECTORY"]) || existing_dir(ENV["TM_PROJECT_DIRECTORY"]) || Dir.pwd
  root, err, status = Open3.capture3("git", "-C", dir, "rev-parse", "--show-toplevel")
  abort_usage("This file is not in a git repo.\n#{err.strip}") unless status.success?
  url, err, status = Open3.capture3("git", "-C", root.strip, "remote", "get-url", "origin")
  abort_usage("No origin remote in #{root.strip}.\n#{err.strip}") unless status.success?
  slug = github_slug(url)
  abort_usage("origin is not a GitHub repo (#{url.strip}).") if slug.nil?
  slug
end

def parse_args(argv)
  args = argv.dup
  dry = !args.delete("--dry-run").nil?
  only = !args.delete("--only-artifacts").nil?
  runs = !args.delete("--runs").nil?
  abort_usage("Pass only one of --only-artifacts or --runs.") if only && runs
  what = nil
  if (i = args.index("--what"))
    args.delete_at(i)
    key = args.delete_at(i)
    abort_usage("--what must be failed, all, or keep2 (got: #{key.inspect}).") unless WHAT.key?(key)
    what = WHAT[key]
  end
  slug = args.reject { |a| a.start_with?("-") }.first
  mode = only ? :artifacts : (runs ? :runs : nil)
  [dry, what, mode, slug]
end

def gh(*args)
  out, status = Open3.capture2e("gh", *args)
  abort_usage("gh failed: #{out.strip}") unless status.success?
  out
end

def json_rows(path, jq)
  out = gh("api", "--paginate", path, "--jq", jq)
  out.lines.reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
end

def fetch_runs(repo)
  json_rows("repos/#{repo}/actions/runs?per_page=100",
    '.workflow_runs[] | {id: .id, conclusion: .conclusion, status: .status, created_at: .created_at, name: .name, run_number: .run_number}')
end

def fetch_artifacts(repo)
  json_rows("repos/#{repo}/actions/artifacts?per_page=100",
    '.artifacts[] | select(.expired == false) | {id: (.id|tostring), bytes: .size_in_bytes, run: .workflow_run.id, name: .name}')
end

def build_plan(runs, arts, what, only_artifacts)
  ordered = runs.sort_by { |r| r["created_at"].to_s }.reverse
  busy_ids = runs.select { |r| r["status"] != "completed" }.map { |r| r["id"] }
  keep = what == :keep2 ? ordered.first(2).map { |r| r["id"] } : []
  completed = runs.select { |r| r["status"] == "completed" }
  run_ids = case what
    when :failed then completed.select { |r| r["conclusion"] == "failure" }.map { |r| r["id"] }
    when :all then completed.map { |r| r["id"] }
    when :keep2 then completed.reject { |r| keep.include?(r["id"]) }.map { |r| r["id"] }
  end
  if only_artifacts
    chosen = case what
      when :all then arts
      when :keep2 then arts.reject { |a| keep.include?(a["run"]) }
      else arts.select { |a| run_ids.include?(a["run"]) }
    end
    chosen = chosen.reject { |a| busy_ids.include?(a["run"]) }
    { :run_ids => [], :artifact_ids => chosen.map { |a| a["id"] }, :bytes => chosen.inject(0) { |s, a| s + a["bytes"].to_i }, :keep => keep, :busy => busy_ids.size }
  else
    bytes = arts.select { |a| run_ids.include?(a["run"]) }.inject(0) { |s, a| s + a["bytes"].to_i }
    { :run_ids => run_ids, :artifact_ids => [], :bytes => bytes, :keep => keep, :busy => busy_ids.size }
  end
end

def describe(repo, what, only_artifacts, plan, runs)
  scope = only_artifacts ? "only artifacts" : "runs, logs, and artifacts"
  lines = ["#{repo}", "#{WHAT_LABEL[what]} — #{scope}"]
  unless plan[:keep].empty?
    kept = runs.select { |r| plan[:keep].include?(r["id"]) }
    lines << "Keeping: " + kept.map { |r| "##{r["run_number"]} #{r["name"]}" }.join("; ")
  end
  if only_artifacts
    n = plan[:artifact_ids].size
    lines << "#{n} artifact#{n == 1 ? "" : "s"}, #{mb(plan[:bytes])}"
  else
    n = plan[:run_ids].size
    lines << "#{n} run#{n == 1 ? "" : "s"}, #{mb(plan[:bytes])} of artifacts, plus their logs"
  end
  if plan[:busy] > 0
    lines << "Skipped #{plan[:busy]} run#{plan[:busy] == 1 ? "" : "s"} still in progress."
  end
  lines.join("\n")
end

def nothing?(plan)
  plan[:run_ids].empty? && plan[:artifact_ids].empty?
end

def tm_ui
  support = ENV["TM_SUPPORT_PATH"]
  abort_usage("TextMate dialog support is not available.") if support.nil? || support.empty?
  require support + "/lib/ui" unless defined?(TextMate) && TextMate.const_defined?(:UI)
  TextMate::UI
end

def choose_what
  picked = tm_ui.request_item(
    :title => "gh delete artifacts",
    :prompt => "Delete what?",
    :items => ["failed runs", "all runs", "all but most recent 2"],
    :default => "failed runs",
    :button1 => "Next",
    :button2 => "Cancel",
  )
  { "failed runs" => :failed, "all runs" => :all, "all but most recent 2" => :keep2 }[picked]
end

def choose_only_artifacts
  # button1 is Return. Cancel is Escape because NSAlert binds that title.
  res = tm_ui.alert(:informational, "gh delete artifacts",
    "Delete only the artifacts, or the runs as well (logs and artifacts)?",
    "Only artifacts", "Runs and artifacts", "Cancel")
  case res
  when "Only artifacts" then true
  when "Runs and artifacts" then false
  else nil
  end
end

def ask(message)
  res = tm_ui.alert(:warning, "gh delete artifacts", message, "Cancel", "Browse", "Delete")
  case res
  when "Browse" then :browse
  when "Delete" then :delete
  else :cancel
  end
end

def actions_url(repo, what)
  url = "https://github.com/#{repo}/actions"
  url += "?query=is%3Afailure" if what == :failed
  url
end

dry, what, mode, slug = parse_args(ARGV)
if slug && slug !~ REPO_RE
  abort_usage("Pass a repo as user/repo (got: #{slug.inspect}).")
end
repo = slug && !slug.empty? ? slug : repo_from_git

what = choose_what if what.nil?
exit 0 if what.nil?
if mode.nil?
  only_artifacts = choose_only_artifacts
  exit 0 if only_artifacts.nil?
else
  only_artifacts = mode == :artifacts
end

runs = fetch_runs(repo)
arts = fetch_artifacts(repo)
plan = build_plan(runs, arts, what, only_artifacts)
text = describe(repo, what, only_artifacts, plan, runs)

if nothing?(plan)
  puts "#{text}\nNothing to delete."
  exit 0
end

if dry
  puts text + "\nDelete?"
  exit 0
end

case ask(text + "\n\nDelete?")
when :browse
  system("open", actions_url(repo, what))
  exit 0
when :delete
  failed = 0
  if only_artifacts
    plan[:artifact_ids].each do |id|
      _out, status = Open3.capture2e("gh", "api", "--method", "DELETE", "repos/#{repo}/actions/artifacts/#{id}")
      failed += 1 unless status.success?
    end
    done = "Deleted #{plan[:artifact_ids].size - failed} artifacts, freed #{mb(plan[:bytes])}."
  else
    plan[:run_ids].each do |id|
      _out, status = Open3.capture2e("gh", "api", "--method", "DELETE", "repos/#{repo}/actions/runs/#{id}")
      failed += 1 unless status.success?
    end
    done = "Deleted #{plan[:run_ids].size - failed} runs and their logs."
  end
  done += " #{failed} failed." if failed > 0
  system("open", actions_url(repo, what))
  puts done
else
  exit 0
end
