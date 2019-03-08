#!/usr/local/bin/ruby
# frozen_string_literal: true

module Fluent
  class Win_CAdvisor_Perf_Input < Input
    Plugin.register_input("wincadvisorperf", self)

    def initialize
      super
      require "yaml"
      require "json"

      require_relative "CAdvisorMetricsAPIClient"
      require_relative "KubernetesApiClient"
      require_relative "oms_common"
      require_relative "omslog"
    end

    config_param :run_interval, :time, :default => "1m"
    config_param :tag, :string, :default => "oms.containerinsights.wincadvisorperf"
    # config_param :mdmtag, :string, :default => "mdm.cadvisorperf"

    def configure(conf)
      super
    end

    def start
      if @run_interval
        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
      end
    end

    def shutdown
      if @run_interval
        @mutex.synchronize {
          @finished = true
          @condition.signal
        }
        @thread.join
      end
    end

    def enumerate()
      time = Time.now.to_f
      begin
        eventStream = MultiEventStream.new
        winNodes = KubernetesApiClient.getWindowsNodes()
        metricData = CAdvisorMetricsAPIClient.getMetrics()
        metricData.each do |record|
          record["DataType"] = "LINUX_PERF_BLOB"
          record["IPName"] = "LogManagement"
          eventStream.add(time, record) if record
          #router.emit(@tag, time, record) if record
        end

        router.emit_stream(@tag, eventStream) if eventStream
        router.emit_stream(@mdmtag, eventStream) if eventStream
        @@istestvar = ENV["ISTEST"]
        if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && eventStream.count > 0)
          $log.info("winCAdvisorPerfEmitStreamSuccess @ #{Time.now.utc.iso8601}")
        end
      rescue => errorStr
        $log.warn "Failed to retrieve cadvisor metric data for windows nodes: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
      end
    end

    def run_periodic
      @mutex.lock
      done = @finished
      until done
        @condition.wait(@mutex, @run_interval)
        done = @finished
        @mutex.unlock
        if !done
          begin
            $log.info("in_win_cadvisor_perf::run_periodic @ #{Time.now.utc.iso8601}")
            enumerate
          rescue => errorStr
            $log.warn "in_win_cadvisor_perf::run_periodic: enumerate Failed to retrieve cadvisor perf metrics for windows nodes: #{errorStr}"
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end
  end # Win_CAdvisor_Perf_Input
end # module
