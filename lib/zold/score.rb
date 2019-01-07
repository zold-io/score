# frozen_string_literal: true

# Copyright (c) 2018-2019 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'openssl'
require 'score_suffix/score_suffix'
require 'time'

# Zold score.
#
# To calculate a score you first have to create a zero score and then
# call its <tt>next()</tt> method:
#
#  first = Score.new(host: 'example.org', invoice: 'PREFIX@0000000000000000')
#  second = first.next
#
# More information about the algorithm you can find in the
# {White Paper}[https://papers.zold.io/wp.pdf].
#
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018-2019 Yegor Bugayenko
# License:: MIT
module Zold
  # Score
  class Score
    # Default strength for the entire system, in production mode. The larger
    # the number, the more difficult it is to find the next score for
    # a node. If the number if too small, the values of the score will be
    # big and the amount of data to be transferred from node to node will
    # increase. The number is set empirically.
    STRENGTH = 8

    # The maximum amount of hours a score can stay "fresh." After that it
    # will be considered expired.
    BEST_BEFORE = 24

    attr_reader :time, :host, :port, :invoice, :suffixes, :strength, :created

    # Makes a new object of the class.
    def initialize(time: Time.now, host:, port: 4096, invoice:, suffixes: [],
      strength: Score::STRENGTH, created: Time.now)
      raise 'Time can\'t be nil' if time.nil?
      unless time.is_a?(Time)
        raise "Time must be Time, while #{time.class.name} is provided"
      end
      @time = time
      raise 'Host can\'t be nil' if host.nil?
      unless /^[0-9a-z\.\-]+$/.match?(host)
        raise "Host \"#{host}\" is in a wrong format"
      end
      @host = host
      raise 'Port can\'t be nil' if port.nil?
      unless port.is_a?(Integer)
        raise "Port must be Integer, while #{port.class.name} is provided"
      end
      if port > 65_535
        raise "Port must be less than 65535, while #{port} is provided"
      end
      unless port.positive?
        raise "Port must be positive integer, while #{port} is provided"
      end
      @port = port
      raise 'Invoice can\'t be nil' if invoice.nil?
      unless /^[a-zA-Z0-9]{8,32}@[a-f0-9]{16}$/.match?(invoice)
        raise "Invoice \"#{invoice}\" is wrong"
      end
      @invoice = invoice
      raise 'Suffixes can\'t be nil' if suffixes.nil?
      raise 'Suffixes are not an array' unless suffixes.is_a?(Array)
      @suffixes = suffixes
      raise 'Strength can\'t be nil' if strength.nil?
      unless strength.positive?
        raise "Strength must be positive integer, while #{strength} is provided"
      end
      @strength = strength
      raise 'Created can\'t be nil' if created.nil?
      unless created.is_a?(Time)
        raise "Created must be Time, while #{created.class.name} is provided"
      end
      @created = created
    end

    # The default no-value score.
    ZERO = Score.new(
      time: Time.now, host: 'localhost',
      invoice: 'NOPREFIX@ffffffffffffffff'
    )

    # Parses it back from the JSON.
    def self.parse_json(json)
      raise 'JSON can\'t be nil' if json.nil?
      Score.new(
        time: Time.parse(json['time']),
        host: json['host'],
        port: json['port'],
        invoice: json['invoice'],
        suffixes: json['suffixes'],
        strength: json['strength']
      )
    end

    # Compare with another Score, by text.
    def ==(other)
      raise 'Can\'t compare with nil' if other.nil?
      to_s == other.to_s
    end

    # Compare with another Score, by value.
    def <(other)
      raise 'Can\'t compare with nil' if other.nil?
      value < other.value
    end

    # Compare with another Score, by value.
    def >(other)
      raise 'Can\'t compare with nil' if other.nil?
      value > other.value
    end

    # Compare with another Score, by value.
    def <=>(other)
      raise 'Can\'t compare with nil' if other.nil?
      value <=> other.value
    end

    # Converts it to a string. You can parse it back
    # using <tt>parse()</tt>.
    def to_s
      pfx, bnf = @invoice.split('@')
      [
        @strength,
        @time.to_i.to_s(16),
        @host,
        @port.to_s(16),
        pfx,
        bnf,
        @suffixes.join(' ')
      ].join(' ')
    end

    # Parses it back from the text generated by <tt>to_s</tt>.
    def self.parse(text)
      raise 'Can\'t parse nil' if text.nil?
      parts = text.split(' ', 7)
      raise "Invalid score, not enough parts in \"#{text}\"" if parts.length < 6
      Score.new(
        time: Time.at(parts[1].hex),
        host: parts[2],
        port: parts[3].hex,
        invoice: "#{parts[4]}@#{parts[5]}",
        suffixes: parts[6] ? parts[6].split(' ') : [],
        strength: parts[0].to_i
      )
    end

    # Returns its crypto hash. Read the White Paper for more information.
    def hash
      raise 'Score has zero value, there is no hash' if @suffixes.empty?
      @suffixes.reduce(prefix) do |pfx, suffix|
        OpenSSL::Digest::SHA256.new("#{pfx} #{suffix}").hexdigest
      end
    end

    # A simple mnemo of the score.
    def to_mnemo
      "#{value}:#{@time.strftime('%H%M')}"
    end

    # Converts the score to a hash, which can be used for JSON presentation
    # of the score.
    def to_h
      {
        value: value,
        host: @host,
        port: @port,
        invoice: @invoice,
        time: @time.utc.iso8601,
        suffixes: @suffixes,
        strength: @strength,
        hash: value.zero? ? nil : hash,
        expired: expired?,
        valid: valid?,
        age: (age / 60).round,
        created: @created.utc.iso8601
      }
    end

    # Returns a new score, which is a copy of the current one, but the amount
    # of hash suffixes is reduced to the <tt>max</tt> provided.
    def reduced(max = 4)
      raise 'Max can\'t be nil' if max.nil?
      raise "Max can't be negative: #{max}" if max.negative?
      Score.new(
        time: @time, host: @host, port: @port, invoice: @invoice,
        suffixes: @suffixes[0..[max, suffixes.count].min - 1],
        strength: @strength
      )
    end

    # Calculates and returns the next score after the current one. This
    # operation may take some time, from a few milliseconds to hours, depending
    # on the CPU power and the <tt>strength</tt> of the current score.
    def next
      raise 'This score is not valid' unless valid?
      if expired?
        return Score.new(
          time: Time.now, host: @host, port: @port, invoice: @invoice,
          suffixes: [], strength: @strength
        )
      end
      suffix = ScoreSuffix.new(suffixes.empty? ? prefix : hash, @strength)
      Score.new(
        time: @time, host: @host, port: @port, invoice: @invoice,
        suffixes: @suffixes + [suffix.value], strength: @strength
      )
    end

    # The age of the score in seconds.
    def age
      Time.now - @time
    end

    # Returns TRUE if the age of the score is over 24 hours.
    def expired?(hours = BEST_BEFORE)
      raise 'Hours can\'t be nil' if hours.nil?
      age > hours * 60 * 60
    end

    # The prefix for the hash calculating algorithm. See the White Paper
    # for more details.
    def prefix
      "#{@time.utc.iso8601} #{@host} #{@port} #{@invoice}"
    end

    # Returns TRUE if the score is valid: all its suffixes correctly consistute
    # the hash, according to the algorithm explained in the White Paper.
    def valid?
      (@suffixes.empty? || hash.end_with?('0' * @strength)) && @time < Time.now
    end

    # Returns the value of the score, from zero and up. The value is basically
    # the amount of hash suffixes inside the score.
    def value
      @suffixes.length
    end

    # Returns TRUE if the value of the score is zero.
    def zero?
      @suffixes.empty?
    end
  end
end
