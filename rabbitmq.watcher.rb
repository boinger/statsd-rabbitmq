#!/usr/bin/env ruby
#
# Author: Jeff Vier <jeff@jeffvier.com>

# all these should should be available after puppet install:
require 'rubygems'
require 'digest'
require 'find'
require 'fileutils'
require 'json'
require 'socket'
require 'resolv'

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
Statsd.host = '127.0.0.1'
Statsd.port = 8125

unless system 'which rabbitmqadmin'
  raise "unable to locate the rabbitmqadmin command"
end

loop do
  overview = JSON.parse(`rabbitmqadmin show overview -f raw_json`)
  Statsd.gauge('rabbitmq.channels', overview[0]['object_totals']['channels'])
  Statsd.gauge('rabbitmq.connections', overview[0]['object_totals']['connections'])
  Statsd.gauge('rabbitmq.consumers', overview[0]['object_totals']['consumers'])
  Statsd.gauge('rabbitmq.exchanges', overview[0]['object_totals']['exchanges'])
  Statsd.gauge('rabbitmq.queues', overview[0]['object_totals']['queues'])

  queues = JSON.parse(`rabbitmqadmin list queues -f raw_json`)
  queues.each do |q|
    name = q['name']
    next unless name
    name.gsub!(/\./, '_')
    next if name.match(/^amq_gen/)

    # rabbitmqadmin may set messages and consumers to nil.
    # I do not know how nil vs. 0 should be interpreted
    # to preserve the nil value, a nil metric will NOT be sent.

    messages = q['messages']
    Statsd.gauge("rabbitmq.queue.#{name}.messages", messages) if messages

    consumers = q['consumers']
    Statsd.gauge("rabbitmq.queue.#{name}.consumers", consumers) if consumers
  end

  sleep 10
end

