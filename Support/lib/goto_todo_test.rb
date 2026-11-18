#!/usr/bin/env ruby -wEutf-8
require 'tmpdir'
require_relative 'goto_todo'

$failures = 0

def check(label)
  yield
rescue GotoTodo::Error => e
  puts "FAIL #{label}: unexpected error: #{e.message}"
  $failures += 1
rescue => e
  puts "FAIL #{label}: #{e.class}: #{e.message}"
  $failures += 1
end

def expect_error(label)
  begin
    yield
    puts "FAIL #{label}: expected an error"
    $failures += 1
  rescue GotoTodo::Error
  end
end

def assert_equal(label, want, got)
  return if want == got
  puts "FAIL #{label}: want #{want.inspect}, got #{got.inspect}"
  $failures += 1
end

check('envy_todo.r.md → envy.r') do
  assert_equal('path', '/work/envy.r', GotoTodo.code_path('/work/envy_todo.r.md'))
end

check('dotted stem and Rmd extension') do
  assert_equal('path', '/work/my.analysis.Rmd', GotoTodo.code_path('/work/my.analysis_todo.Rmd.md'))
end

check('extension case is kept') do
  assert_equal('path', '/work/Envy.R', GotoTodo.code_path('/work/Envy_todo.R.MD'))
end

expect_error('code file is not a todo') { GotoTodo.code_path('/work/envy.r') }
expect_error('todo name with no code extension') { GotoTodo.code_path('/work/envy_todo.md') }
expect_error('unsaved') { GotoTodo.target({}) }

check('single #34') do
  assert_equal('n', 34, GotoTodo.line_number('- [ ] fix model #34'))
end

check('last #number when the caret is elsewhere') do
  line = '- [ ] see #12 and also #34'
  assert_equal('n', 34, GotoTodo.line_number(line, 0))
end

check('caret on an earlier #number') do
  line = '- [ ] see #12 and also #34'
  # caret on the '1' of #12
  at = line.index('#12') + 2
  assert_equal('n', 12, GotoTodo.line_number(line, at))
end

check('caret just after #12') do
  line = '- [ ] see #12 and also #34'
  at = line.index('#12') + '#12'.bytesize
  assert_equal('n', 12, GotoTodo.line_number(line, at))
end

check('heading is not a line number') do
  expect_error('heading') { GotoTodo.line_number('## 34 notes') }
  expect_error('glued hashes') { GotoTodo.line_number('##34') }
end

expect_error('no marker') { GotoTodo.line_number('- [ ] fix model') }
expect_error('line zero') { GotoTodo.line_number('reset #0') }

check('byte caret after a multibyte character') do
  line = '- [ ] café #8'
  at = line.bytesize # caret at end, so the only match is used
  assert_equal('n', 8, GotoTodo.line_number(line, at))
  # caret on #8, counted in bytes (é is two bytes)
  hash_at = line.index('#8')
  byte_at = line.byteslice(0, hash_at).bytesize + 1
  assert_equal('byte', 8, GotoTodo.line_number(line, byte_at))
end

check('txmt url') do
  url = GotoTodo.txmt_url('/work/envy.r', 34)
  assert_equal('url', 'txmt://open?url=file:///work/envy.r&line=34', url)
end

check('txmt url encodes space and utf-8') do
  url = GotoTodo.txmt_url("/work/my file/caf\u00e9.r", 2)
  assert_equal('url', 'txmt://open?url=file:///work/my%20file/caf%C3%A9.r&line=2', url)
end

check('target uses the selection and the paired file') do
  Dir.mktmpdir do |dir|
    code = File.join(dir, 'envy.r')
    File.write(code, "x\n")
    env = {
      'TM_FILEPATH' => File.join(dir, 'envy_todo.r.md'),
      'TM_CURRENT_LINE' => '- [ ] see #12 and also #34',
      'TM_SELECTED_TEXT' => '#12',
      'TM_LINE_INDEX' => '0'
    }
    got_code, n, url = GotoTodo.target(env)
    assert_equal('code', code, got_code)
    assert_equal('n', 12, n)
    assert_equal('url', GotoTodo.txmt_url(code, 12), url)
  end
end

expect_error('missing code file') do
  GotoTodo.target(
    'TM_FILEPATH' => '/no/such/envy_todo.r.md',
    'TM_CURRENT_LINE' => '- [ ] fix model #34'
  )
end

if $failures == 0
  puts 'ok'
else
  puts "#{$failures} failed"
  exit 1
end
