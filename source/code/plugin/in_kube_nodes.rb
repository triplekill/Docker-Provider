#!/usr/local/bin/ruby
# frozen_string_literal: true

module Fluent

    class Kube_nodeInventory_Input < Input
      Plugin.register_input('kubenodeinventory', self)
  
      @@ContainerNodeInventoryTag = 'oms.api.ContainerNodeInventory'
      @@MDMKubeNodeInventoryTag = 'mdm.kubenodeinventory'

      def initialize
        super
        require 'yaml'
        require 'json'
  
        require_relative 'KubernetesApiClient'
        require_relative 'ApplicationInsightsUtility'
        require_relative 'oms_common'
        require_relative 'omslog'

      end
  
      config_param :run_interval, :time, :default => '1m'
      config_param :tag, :string, :default => "oms.containerinsights.KubeNodeInventory"
  
      def configure (conf)
        super
      end
  
      def start
        if @run_interval
          @finished = false
          @condition = ConditionVariable.new
          @mutex = Mutex.new
          @thread = Thread.new(&method(:run_periodic))
          @@nodeTelemetryTimeTracker = DateTime.now.to_time.to_i
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
  
      def enumerate
        currentTime = Time.now
        emitTime = currentTime.to_f
        batchTime = currentTime.utc.iso8601
        telemetrySent = false
        $log.info("in_kube_nodes::enumerate : Getting nodes from Kube API @ #{Time.now.utc.iso8601}")
        nodeInventory = JSON.parse(KubernetesApiClient.getKubeResourceInfo('nodes').body)
        $log.info("in_kube_nodes::enumerate : Done getting nodes from Kube API @ #{Time.now.utc.iso8601}")
          begin
            if(!nodeInventory.empty?)
              eventStream = MultiEventStream.new
              containerNodeInventoryEventStream = MultiEventStream.new 
                #get node inventory 
                nodeInventory['items'].each do |items|
                    record = {}
                    # Sending records for ContainerNodeInventory
                    containerNodeInventoryRecord = {}
                    containerNodeInventoryRecord['CollectionTime'] = batchTime #This is the time that is mapped to become TimeGenerated
                    containerNodeInventoryRecord['Computer'] = items['metadata']['name']

                    record['CollectionTime'] = batchTime #This is the time that is mapped to become TimeGenerated
                    record['Computer'] = items['metadata']['name'] 
                    record['ClusterName'] = KubernetesApiClient.getClusterName
                    record['ClusterId'] = KubernetesApiClient.getClusterId  
                    record['CreationTimeStamp'] = items['metadata']['creationTimestamp'] 
                    record['Labels'] = [items['metadata']['labels']]
                    record['Status'] = ""

                    # Refer to https://kubernetes.io/docs/concepts/architecture/nodes/#condition for possible node conditions.
                    # We check the status of each condition e.g. {"type": "OutOfDisk","status": "False"} . Based on this we 
                    # populate the KubeNodeInventory Status field. A possible value for this field could be "Ready OutofDisk"
                    # implying that the node is ready for hosting pods, however its out of disk.
                    
                    if items['status'].key?("conditions") && !items['status']['conditions'].empty?
                      allNodeConditions="" 
                      items['status']['conditions'].each do |condition|
                          if condition['status'] == "True"
                            if !allNodeConditions.empty?
                              allNodeConditions = allNodeConditions + "," + condition['type']
                            else
                              allNodeConditions = condition['type']
                            end
                          end 
                          #collect last transition to/from ready (no matter ready is true/false)
                          if condition['type'] == "Ready" && !condition['lastTransitionTime'].nil?
                            record['LastTransitionTimeReady'] = condition['lastTransitionTime']
                          end
                      end 
                      if !allNodeConditions.empty?
                        record['Status'] = allNodeConditions
                      end

                    end

                    nodeInfo = items['status']['nodeInfo']
                    record['KubeletVersion'] = nodeInfo['kubeletVersion']
                    record['KubeProxyVersion'] = nodeInfo['kubeProxyVersion']
                    containerNodeInventoryRecord['OperatingSystem'] = nodeInfo['osImage']
                    dockerVersion = nodeInfo['containerRuntimeVersion']
                    dockerVersion.slice! "docker://"
                    containerNodeInventoryRecord['DockerVersion'] = dockerVersion
                    # ContainerNodeInventory data for docker version and operating system.
                    containerNodeInventoryEventStream.add(emitTime, containerNodeInventoryRecord) if containerNodeInventoryRecord

                    wrapper = {
                      "DataType"=>"KUBE_NODE_INVENTORY_BLOB",
                      "IPName"=>"ContainerInsights",
                      "DataItems"=>[record.each{|k,v| record[k]=v}]
                    }
                    eventStream.add(emitTime, wrapper) if wrapper
                    # Adding telemetry to send node telemetry every 5 minutes
                    timeDifference =  (DateTime.now.to_time.to_i - @@nodeTelemetryTimeTracker).abs
                    timeDifferenceInMinutes = timeDifference/60
                    if (timeDifferenceInMinutes >= 5)
                      properties = {}
                      properties["Computer"] = record["Computer"]
                      properties["KubeletVersion"] = record["KubeletVersion"]
                      capacityInfo = items['status']['capacity']
                      ApplicationInsightsUtility.sendMetricTelemetry("NodeCoreCapacity", capacityInfo["cpu"] , properties)
                      ApplicationInsightsUtility.sendMetricTelemetry("NodeMemory", capacityInfo["memory"] , properties)
                      telemetrySent = true
                    end
                end 
                router.emit_stream(@tag, eventStream) if eventStream
                router.emit_stream(@@MDMKubeNodeInventoryTag, eventStream) if eventStream
                router.emit_stream(@@ContainerNodeInventoryTag, containerNodeInventoryEventStream) if containerNodeInventoryEventStream
                if telemetrySent == true
                  @@nodeTelemetryTimeTracker = DateTime.now.to_time.to_i
                end
                @@istestvar = ENV['ISTEST']
                if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp('true') == 0 && eventStream.count > 0)
                  $log.info("kubeNodeInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
                end
            end  
          rescue  => errorStr
            $log.warn "Failed to retrieve node inventory: #{errorStr}"
            $log.debug_backtrace(errorStr.backtrace)
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
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
              $log.info("in_kube_nodes::run_periodic @ #{Time.now.utc.iso8601}")
              enumerate
            rescue => errorStr
              $log.warn "in_kube_nodes::run_periodic: enumerate Failed to retrieve node inventory: #{errorStr}"
              ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
            end
          end
          @mutex.lock
        end
        @mutex.unlock
      end
  
    end # Kube_Node_Input
  
  end # module
  
  