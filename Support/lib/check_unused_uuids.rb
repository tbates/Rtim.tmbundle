#!/usr/bin/env ruby -wEutf-8
require ENV['TM_SUPPORT_PATH'] + '/lib/ui'
require 'json'
require 'shellwords'

bundles_dir = File.expand_path('~/Library/Application Support/TextMate/Bundles')

# TM_BUNDLE_PATH follows the front document's grammar, so it is nil (or some
# other bundle) when this command is run from the wrong context. Fall back
# to asking which installed bundle to check.
bundle = ENV['TM_BUNDLE_PATH']
bundle = nil unless bundle && File.directory?(bundle)
if bundle.nil?
  names = Dir[File.join(bundles_dir, '*.tmbundle')].map { |p| File.basename(p, '.tmbundle') }.sort
  pick = TextMate::UI.request_item(:title => 'Unused UUIDs',
                                   :prompt => 'Check which bundle for unused UUIDs?',
                                   :items => names)
  if pick.nil?
    puts 'Cancelled.'
    exit
  end
  bundle = File.join(bundles_dir, pick + '.tmbundle')
end

# The checker ships with Rtim but works on any bundle: prefer a copy inside
# the target bundle, fall back to Rtim's copy.
checker = File.join(bundle, 'Support', 'lib', 'unused_uuids.py')
unless File.file?(checker)
  rtim_checker = File.join(bundles_dir, 'Rtim.tmbundle', 'Support', 'lib', 'unused_uuids.py')
  checker = rtim_checker if File.file?(rtim_checker)
end
unless File.file?(checker)
  puts "No unused-UUID checker installed for #{bundle}."
  exit
end

def check(checker, bundle)
  JSON.parse(`python3 #{Shellwords.escape(checker)} --json #{Shellwords.escape(bundle)}`)
end

report  = check(checker, bundle)
orphans = report['orphans']
name    = report['bundle']

lines = []
headline = "#{name}: #{orphans.size} orphan UUID#{orphans.size == 1 ? '' : 's'}"
lines << headline
orphans.first(12).each do |entry|
  lines << "  #{entry['uuid'][0, 8]} in #{entry['menus'].join(', ')}"
end
lines << "  …and #{orphans.size - 12} more" if orphans.size > 12
report['gutted_categories'].each do |entry|
  lines << "GUTTED (nothing in it resolves): #{entry['name']} — left alone"
end
report['dead_categories'].each do |entry|
  lines << "UNPLACED (never listed, cannot open): #{entry['name']} — left alone"
end
report['invalid_entries'].each do |entry|
  lines << "INVALID entry in #{entry['menu']} slot #{entry['index']} (#{entry['value'].inspect}) — left alone"
end

if orphans.empty?
  lines << 'Clean — nothing to strip.'
else
  if TextMate::UI.request_confirmation(
       :title   => 'Unused UUIDs',
       :prompt  => "Strip #{orphans.size} orphan UUID#{orphans.size == 1 ? '' : 's'} from #{name} menus?",
       :button1 => 'Strip them',
       :button2 => 'Leave them')
    res = JSON.parse(`python3 #{Shellwords.escape(checker)} --strip #{Shellwords.escape(bundle)}`)
    lines << "Stripped #{res['stripped']} (backup #{res['backup']})."
    fresh = check(checker, bundle)
    lines << (fresh['orphans'].empty? ? 'Verified clean.' : 'WARNING: orphans remain — re-run to inspect.')
  else
    lines << 'Left alone.'
  end
end

puts lines.join("\n")
