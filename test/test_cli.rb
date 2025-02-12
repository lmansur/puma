require_relative "helper"

require "puma/cli"
require "json"

class TestCLI < Minitest::Test
  def setup
    @environment = 'production'
    @tmp_file = Tempfile.new("puma-test")
    @tmp_path = @tmp_file.path
    @tmp_file.close!

    @tmp_path2 = "#{@tmp_path}2"

    File.unlink @tmp_path  if File.exist? @tmp_path
    File.unlink @tmp_path2 if File.exist? @tmp_path2

    @wait, @ready = IO.pipe

    @events = Puma::Events.strings
    @events.on_booted { @ready << "!" }
  end

  def wait_booted
    @wait.sysread 1
  end

  def teardown
    File.unlink @tmp_path if File.exist? @tmp_path
    File.unlink @tmp_path2 if File.exist? @tmp_path2

    @wait.close
    @ready.close
  end

  def test_pid_file
    cli = Puma::CLI.new ["--pidfile", @tmp_path]
    cli.launcher.write_pid

    assert_equal File.read(@tmp_path).strip.to_i, Process.pid
  end

  def test_control_for_tcp
    tcp  = UniquePort.call
    cntl = UniquePort.call
    url = "tcp://127.0.0.1:#{cntl}/"

    cli = Puma::CLI.new ["-b", "tcp://127.0.0.1:#{tcp}",
                         "--control", url,
                         "--control-token", "",
                         "test/rackup/lobster.ru"], @events

    t = Thread.new do
      cli.run
    end

    wait_booted

    s = TCPSocket.new "127.0.0.1", cntl
    s << "GET /stats HTTP/1.0\r\n\r\n"
    body = s.read
    s.close

    assert_match(/{ "started_at": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", "backlog": 0, "running": 0, "pool_capacity": 16, "max_threads": 16 }/, body.split(/\r?\n/).last)
    assert_match(/{ "started_at": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", "backlog": 0, "running": 0, "pool_capacity": 16, "max_threads": 16 }/, Puma.stats)

  ensure
    cli.launcher.stop
    t.join
  end

  def test_control_clustered
    skip NO_FORK_MSG  unless HAS_FORK
    skip UNIX_SKT_MSG unless UNIX_SKT_EXIST
    url = "unix://#{@tmp_path}"

    cli = Puma::CLI.new ["-b", "unix://#{@tmp_path2}",
                         "-t", "2:2",
                         "-w", "2",
                         "--control", url,
                         "--control-token", "",
                         "test/rackup/lobster.ru"], @events

    t = Thread.new { cli.run }

    wait_booted

    s = UNIXSocket.new @tmp_path
    s << "GET /stats HTTP/1.0\r\n\r\n"
    body = s.read

    require 'json'
    status = JSON.parse(body.split("\n").last)

    assert_equal 2, status["workers"]

    # wait until the first status ping has come through
    sleep 6
    s = UNIXSocket.new @tmp_path
    s << "GET /stats HTTP/1.0\r\n\r\n"
    body = s.read
    assert_match(/\{ "started_at": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", "workers": 2, "phase": 0, "booted_workers": 2, "old_workers": 0, "worker_status": \[\{ "started_at": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", "pid": \d+, "index": 0, "phase": 0, "booted": true, "last_checkin": "[^"]+", "last_status": \{ "backlog":0, "running":2, "pool_capacity":2, "max_threads": 2 \} \},\{ "started_at": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", "pid": \d+, "index": 1, "phase": 0, "booted": true, "last_checkin": "[^"]+", "last_status": \{ "backlog":0, "running":2, "pool_capacity":2, "max_threads": 2 \} \}\] \}/, body.split("\r\n").last)

    cli.launcher.stop
    t.join
  end

  def test_control
    skip UNIX_SKT_MSG unless UNIX_SKT_EXIST
    url = "unix://#{@tmp_path}"

    cli = Puma::CLI.new ["-b", "unix://#{@tmp_path2}",
                         "--control", url,
                         "--control-token", "",
                         "test/rackup/lobster.ru"], @events

    t = Thread.new { cli.run }

    wait_booted

    s = UNIXSocket.new @tmp_path
    s << "GET /stats HTTP/1.0\r\n\r\n"
    body = s.read

    assert_match(/{ "started_at": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", "backlog": 0, "running": 0, "pool_capacity": 16, "max_threads": 16 }/, body.split("\r\n").last)

    cli.launcher.stop
    t.join
  end

  def test_control_stop
    skip UNIX_SKT_MSG unless UNIX_SKT_EXIST
    url = "unix://#{@tmp_path}"

    cli = Puma::CLI.new ["-b", "unix://#{@tmp_path2}",
                         "--control", url,
                         "--control-token", "",
                         "test/rackup/lobster.ru"], @events

    t = Thread.new { cli.run }

    wait_booted

    s = UNIXSocket.new @tmp_path
    s << "GET /stop HTTP/1.0\r\n\r\n"
    body = s.read

    assert_equal '{ "status": "ok" }', body.split("\r\n").last

    t.join
  end

  def control_gc_stats(uri, cntl)
    cli = Puma::CLI.new ["-b", uri,
                         "--control", cntl,
                         "--control-token", "",
                         "test/rackup/lobster.ru"], @events

    t = Thread.new do
      cli.run
    end

    wait_booted

    s = yield
    s << "GET /gc-stats HTTP/1.0\r\n\r\n"
    body = s.read
    s.close

    lines = body.split("\r\n")
    json_line = lines.detect { |l| l[0] == "{" }
    pairs = json_line.scan(/\"[^\"]+\": [^,]+/)
    gc_stats = {}
    pairs.each do |p|
      p =~ /\"([^\"]+)\": ([^,]+)/ || raise("Can't parse #{p.inspect}!")
      gc_stats[$1] = $2
    end
    gc_count_before = gc_stats["count"].to_i

    s = yield
    s << "GET /gc HTTP/1.0\r\n\r\n"
    body = s.read # Ignored
    s.close

    s = yield
    s << "GET /gc-stats HTTP/1.0\r\n\r\n"
    body = s.read
    s.close

    lines = body.split("\r\n")
    json_line = lines.detect { |l| l[0] == "{" }
    gc_stats = JSON.parse(json_line)
    gc_count_after = gc_stats["count"].to_i

    # Hitting the /gc route should increment the count by 1
    assert(gc_count_before < gc_count_after, "make sure a gc has happened")

  ensure
    cli.launcher.stop if cli
    t.join
  end

  def test_control_gc_stats_tcp
    skip_on :jruby, suffix: " - Hitting /gc route does not increment count"
    uri  = "tcp://127.0.0.1:#{UniquePort.call}/"
    cntl_port = UniquePort.call
    cntl = "tcp://127.0.0.1:#{cntl_port}/"

    control_gc_stats(uri, cntl) { TCPSocket.new "127.0.0.1", cntl_port }
  end

  def test_control_gc_stats_unix
    skip_on :jruby, suffix: " - Hitting /gc route does not increment count"
    skip UNIX_SKT_MSG unless UNIX_SKT_EXIST

    uri  = "unix://#{@tmp_path2}"
    cntl = "unix://#{@tmp_path}"

    control_gc_stats(uri, cntl) { UNIXSocket.new @tmp_path }
  end

  def test_tmp_control
    skip_on :jruby, suffix: " - Unknown issue"

    cli = Puma::CLI.new ["--state", @tmp_path, "--control", "auto"]
    cli.launcher.write_state

    data = YAML.load File.read(@tmp_path)

    assert_equal Process.pid, data["pid"]

    url = data["control_url"]

    m = %r!unix://(.*)!.match(url)

    assert m, "'#{url}' is not a URL"
  end

  def test_state_file_callback_filtering
    skip NO_FORK_MSG unless HAS_FORK
    cli = Puma::CLI.new [ "--config", "test/config/state_file_testing_config.rb",
                          "--state", @tmp_path ]
    cli.launcher.write_state

    data = YAML.load_file(@tmp_path)

    keys_not_stripped = data.keys & Puma::CLI::KEYS_NOT_TO_PERSIST_IN_STATE
    assert_empty keys_not_stripped
  end

  def test_log_formatter_default_single
    cli = Puma::CLI.new [ ]
    assert_instance_of Puma::Events::DefaultFormatter, cli.launcher.events.formatter
  end

  def test_log_formatter_default_clustered
    skip NO_FORK_MSG unless HAS_FORK

    cli = Puma::CLI.new [ "-w 2" ]
    assert_instance_of Puma::Events::PidFormatter, cli.launcher.events.formatter
  end

  def test_log_formatter_custom_single
    cli = Puma::CLI.new [ "--config", "test/config/custom_log_formatter.rb" ]
    assert_instance_of Proc, cli.launcher.events.formatter
    assert_match(/^\[.*\] \[.*\] .*: test$/, cli.launcher.events.format('test'))
  end

  def test_log_formatter_custom_clustered
    skip NO_FORK_MSG unless HAS_FORK

    cli = Puma::CLI.new [ "--config", "test/config/custom_log_formatter.rb", "-w 2" ]
    assert_instance_of Proc, cli.launcher.events.formatter
    assert_match(/^\[.*\] \[.*\] .*: test$/, cli.launcher.events.format('test'))
  end

  def test_state
    url = "tcp://127.0.0.1:#{UniquePort.call}"
    cli = Puma::CLI.new ["--state", @tmp_path, "--control", url]
    cli.launcher.write_state

    data = YAML.load File.read(@tmp_path)

    assert_equal Process.pid, data["pid"]
    assert_equal url, data["control_url"]
  end

  def test_load_path
    Puma::CLI.new ["--include", 'foo/bar']

    assert_equal 'foo/bar', $LOAD_PATH[0]
    $LOAD_PATH.shift

    Puma::CLI.new ["--include", 'foo/bar:baz/qux']

    assert_equal 'foo/bar', $LOAD_PATH[0]
    $LOAD_PATH.shift
    assert_equal 'baz/qux', $LOAD_PATH[0]
    $LOAD_PATH.shift
  end

  def test_environment
    ENV.delete 'RACK_ENV'

    Puma::CLI.new ["--environment", @environment]

    assert_equal ENV['RACK_ENV'], @environment
  end
end
