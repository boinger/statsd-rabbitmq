#!/usr/bin/env ruby
#
# Author: Jeff Vier <jeff@jeffvier.com>

require 'rubygems'
require 'digest'
require 'find'
require 'fileutils'
require 'json'
require 'socket'
require 'resolv'

require 'optparse'

options = {
  :prefix => Socket.gethostname,
  :interval => 10,
  :host => '127.0.0.1',
  :port => 8125,
  :queues => false,
  :rmquser => 'guest',
  :rmqpass => 'guest',
  :rmqhost => '127.0.0.1',
  :rmqport => 15672
}
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on('-P', '--prefix [STATSD_PREFIX]', "metric prefix (default: #{options[:prefix]})")     { |prefix|   options[:prefix] = "#{prefix}" }
  opts.on('-i', '--interval [SEC]',"reporting interval (default: #{options[:interval]})")       { |interval| options[:interval] = interval }
  opts.on('-h', '--host [HOST]',   "statsd host (default: #{options[:host]})")                  { |host|     options[:host] = host }
  opts.on('-p', '--port [PORT]',   "statsd port (default: #{options[:port]})")                  { |port|     options[:port] = port }
  opts.on('-u', '--rmquser [RABBITMQ_USER]',   "rabbitmq user (default: #{options[:rmquser]})") { |rmquser|  options[:rmquser] = rmquser }
  opts.on('-s', '--rmqpass [RABBITMQ_PASS]',   "rabbitmq pass (default: #{options[:rmqpass]})") { |rmqpass|  options[:rmqpass] = rmqpass }
  opts.on('-r', '--rmqhost [RABBITMQ_HOST]',   "rabbitmq host (default: #{options[:rmqhost]})") { |rmqhost|  options[:rmqhost] = rmqhost }
  opts.on('-b', '--rmqport [RABBITMQ_PORT]',   "rabbitmq port (default: #{options[:rmqport]})") { |rmqport|  options[:rmqport] = rmqport }
  opts.on('-q', '--[no-]queues',   "report queue metrics (default: #{options[:queues]})")       { |queues|   options[:queues] = queues }
end.parse!

###############################################################
# Typical StatsD class, pasted to avoid an external dependency:
# Stolen from https://github.com/bvandenbos/statsd-client

class Statsd

  Version = '0.0.8'

  class << self

    attr_accessor :host, :port

    def host_ip_addr
      @host_ip_addr ||= Resolv.getaddress(host)
    end

    def host=(h)
      @host_ip_addr = nil
      @host = h
    end

    # +stat+ to log timing for
    # +time+ is the time to log in ms
    def timing(stat, time = nil, sample_rate = 1)
      if block_given?
        start_time = Time.now.to_f
        yield
        time = ((Time.now.to_f - start_time) * 1000).floor
      end
      send_stats("#{stat}:#{time}|ms", sample_rate)
    end

    def gauge(stat, value, sample_rate = 1)
      send_stats("#{stat}:#{value}|g", sample_rate)
    end

    # +stats+ can be a string or an array of strings
    def increment(stats, sample_rate = 1)
      update_counter stats, 1, sample_rate
    end

    # +stats+ can be a string or an array of strings
    def decrement(stats, sample_rate = 1)
      update_counter stats, -1, sample_rate
    end

    # +stats+ can be a string or array of strings
    def update_counter(stats, delta = 1, sample_rate = 1)
      stats = Array(stats)
      send_stats(stats.map { |s| "#{s}:#{delta}|c" }, sample_rate)
    end

    private

    def send_stats(data, sample_rate = 1)
      data = Array(data)
      sampled_data = []

      # Apply sample rate if less than one
      if sample_rate < 1
        data.each do |d|
          if rand <= sample_rate
            sampled_data << "#{d}|@#{sample_rate}"
          end
        end
        data = sampled_data
      end

      return if data.empty?

      raise "host and port must be set" unless host && port

      begin
        sock = UDPSocket.new
        data.each do |d|
          sock.send(d, 0, host_ip_addr, port)
        end
      rescue => e
        puts "UDPSocket error: #{e}"
      ensure
        sock.close
      end
      true
    end
  end
end

################################################################################

include FileUtils # allows use of FileUtils methods without the FileUtils:: prefix ie: mv_f(file, file2) or rm_rf(dir)

STDOUT.sync = true # don't buffer STDOUT
Statsd.host = options[:host]
Statsd.port = options[:port]

unless system 'which rabbitmqadmin'
  raise "unable to locate the rabbitmqadmin command"
end

loop do
  overview = JSON.parse(`rabbitmqadmin --host #{options[:rmqhost]} --port #{options[:rmqport]} --user #{options[:rmquser]} --password #{options[:rmqpass]} show overview -f raw_json`)
  prefix = "#{options[:prefix]}.overview.object_totals"
  Statsd.gauge("#{prefix}.channels", overview[0]['object_totals']['channels'])
  Statsd.gauge("#{prefix}.connections", overview[0]['object_totals']['connections'])
  Statsd.gauge("#{prefix}.consumers", overview[0]['object_totals']['consumers'])
  Statsd.gauge("#{prefix}.exchanges", overview[0]['object_totals']['exchanges'])
  Statsd.gauge("#{prefix}.queues", overview[0]['object_totals']['queues'])

  if options[:queues]
    queues = JSON.parse(`rabbitmqadmin --host #{options[:rmqhost]} --port #{options[:rmqport]} --user #{options[:rmquser]} --password #{options[:rmqpass]} list queues -f raw_json`)
    queues.each do |queue|
      if queue.key?('name')
        prefix = "#{options[:prefix]}.queues.#{queue['name']}"
        Statsd.gauge("#{prefix}.active_consumers", queue['active_consumers'])
        Statsd.gauge("#{prefix}.consumers", queue['consumers'])
        Statsd.gauge("#{prefix}.memory", queue['memory'])
        Statsd.gauge("#{prefix}.messages", queue['messages'])
        Statsd.gauge("#{prefix}.messages_ready", queue['messages_ready'])
        Statsd.gauge("#{prefix}.messages_unacknowledged", queue['messages_unacknowledged'])
        Statsd.gauge("#{prefix}.avg_egress_rate", queue['backing_queue_status']['avg_egress_rate'])   if queue['backing_queue_status']
        Statsd.gauge("#{prefix}.avg_ingress_rate", queue['backing_queue_status']['avg_ingress_rate']) if queue['backing_queue_status']
        if queue.key?('message_stats')
          Statsd.gauge("#{prefix}.ack_rate", queue['message_stats']['ack_details']['rate'])                  if queue['message_stats']['ack_details']
          Statsd.gauge("#{prefix}.deliver_rate", queue['message_stats']['deliver_details']['rate'])          if queue['message_stats']['deliver_details']
          Statsd.gauge("#{prefix}.deliver_get_rate", queue['message_stats']['deliver_get_details']['rate'])  if queue['message_stats']['deliver_get_details']
          Statsd.gauge("#{prefix}.publish_rate", queue['message_stats']['publish_details']['rate'])          if queue['message_stats']['publish_details']
        end
      end
    end
  end

  sleep options[:interval]
end
