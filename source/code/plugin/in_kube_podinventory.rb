#!/usr/local/bin/ruby
# frozen_string_literal: true

module Fluent

  class Kube_PodInventory_Input < Input
    Plugin.register_input('kubepodinventory', self)

    def initialize
      super
      require 'yaml'
      require 'json'
      require 'set'

      require_relative 'KubernetesApiClient'
      require_relative 'ApplicationInsightsUtility'
      require_relative 'oms_common'
      require_relative 'omslog'

      @@ReplicasetControllerType = 'ReplicaSet'
    end

    config_param :run_interval, :time, :default => '1m'
    config_param :tag, :string, :default => "oms.containerinsights.KubePodInventory"

    def configure (conf)
      super
    end

    def start
      if @run_interval
        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
        @@podTelemetryTimeTracker = DateTime.now.to_time.to_i
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

    def enumerate(podList = nil) 
        if podList.nil?
          $log.info("in_kube_podinventory::enumerate : Getting pods from Kube API @ #{Time.now.utc.iso8601}")
          podInventory = JSON.parse(KubernetesApiClient.getKubeResourceInfo('pods').body)
          $log.info("in_kube_podinventory::enumerate : Done getting pods from Kube API @ #{Time.now.utc.iso8601}")          
        else
          podInventory = podList
        end
        begin
          if(!podInventory.empty? && podInventory.key?("items") && !podInventory['items'].empty?)
            #get pod inventory & services 
            $log.info("in_kube_podinventory::enumerate : Getting services from Kube API @ #{Time.now.utc.iso8601}")
            serviceList = JSON.parse(KubernetesApiClient.getKubeResourceInfo('services').body)
            $log.info("in_kube_podinventory::enumerate : Done getting services from Kube API @ #{Time.now.utc.iso8601}")
            parse_and_emit_records(podInventory, serviceList)
          else  
            $log.warn "Received empty podInventory"
          end  
        rescue  => errorStr
          $log.warn "Failed in enumerate pod inventory: #{errorStr}"
          $log.debug_backtrace(errorStr.backtrace)
          ApplicationInsightsUtility.sendExceptionTelemetry(errorStr, @@ReplicasetControllerType)
        end  
    end

    def parse_and_emit_records(podInventory, serviceList)
      currentTime = Time.now
      emitTime = currentTime.to_f
      batchTime = currentTime.utc.iso8601
      eventStream = MultiEventStream.new
      controllerSet = Set.new []
      telemetryFlush = false
      begin #begin block start
        podInventory['items'].each do |items| #podInventory block start
          records = []
          record = {}
          record['CollectionTime'] = batchTime #This is the time that is mapped to become TimeGenerated
          record['Name'] = items['metadata']['name']
          podNameSpace = items['metadata']['namespace']
         
          if podNameSpace.eql?("kube-system") && !items['metadata'].key?("ownerReferences")
            # The above case seems to be the only case where you have horizontal scaling of pods
            # but no controller, in which case cAdvisor picks up kubernetes.io/config.hash
            # instead of the actual poduid. Since this uid is not being surface into the UX
            # its ok to use this.
            # Use kubernetes.io/config.hash to be able to correlate with cadvisor data
            podUid = items['metadata']['annotations']['kubernetes.io/config.hash']
          else
            podUid = items['metadata']['uid']
          end
          record['PodUid'] = podUid
          record['PodLabel'] = [items['metadata']['labels']]
          record['Namespace'] = podNameSpace
          record['PodCreationTimeStamp'] = items['metadata']['creationTimestamp']
          #for unscheduled (non-started) pods startTime does NOT exist
          if !items['status']['startTime'].nil?
            record['PodStartTime'] = items['status']['startTime']
          else
            record['PodStartTime'] = ""
          end
          #podStatus
          # the below is for accounting 'NodeLost' scenario, where-in the pod(s) in the lost node is still being reported as running
          podReadyCondition = true
          if !items['status']['reason'].nil? && items['status']['reason'] == "NodeLost" && !items['status']['conditions'].nil?
            items['status']['conditions'].each do |condition|
              if condition['type'] == "Ready" && condition['status'] == "False"
                podReadyCondition = false
                break
              end
            end
          end
          if podReadyCondition == false
            record['PodStatus'] = "Unknown"
          else
            record['PodStatus'] = items['status']['phase']
          end
          #for unscheduled (non-started) pods podIP does NOT exist
          if !items['status']['podIP'].nil?
            record['PodIp'] =items['status']['podIP']
          else
            record['PodIp'] = ""
          end
          #for unscheduled (non-started) pods nodeName does NOT exist
          if !items['spec']['nodeName'].nil?
            record['Computer'] = items['spec']['nodeName']
          else
            record['Computer'] = ""
          end  
          record['ClusterId'] = KubernetesApiClient.getClusterId
          record['ClusterName'] = KubernetesApiClient.getClusterName
          record['ServiceName'] = getServiceNameFromLabels(items['metadata']['namespace'], items['metadata']['labels'], serviceList)
           # Adding telemetry to send pod telemetry every 5 minutes
           timeDifference =  (DateTime.now.to_time.to_i - @@podTelemetryTimeTracker).abs
           timeDifferenceInMinutes = timeDifference/60
           if (timeDifferenceInMinutes >= 5)
             telemetryFlush = true
           end
          if !items['metadata']['ownerReferences'].nil?
            record['ControllerKind'] = items['metadata']['ownerReferences'][0]['kind']
            record['ControllerName'] = items['metadata']['ownerReferences'][0]['name']
            if telemetryFlush == true
              controllerSet.add(record['ControllerKind'] + record['ControllerName'])
            end
          end
          podRestartCount = 0
          record['PodRestartCount'] = 0 
          if items['status'].key?("containerStatuses") && !items['status']['containerStatuses'].empty? #container status block start
            items['status']['containerStatuses'].each do |container|
              containerRestartCount = 0		
              #container Id is of the form 		
              #docker://dfd9da983f1fd27432fb2c1fe3049c0a1d25b1c697b2dc1a530c986e58b16527	
              if !container['containerID'].nil?	
                record['ContainerID'] = container['containerID'].split("//")[1]		
              else 
                # for containers that have image issues (like invalid image/tag etc..) this will be empty. do not make it all 0
                record['ContainerID'] = ""  
              end
              #keeping this as <PodUid/container_name> which is same as InstanceName in perf table		
              record['ContainerName'] = podUid + "/" +container['name']		
              #Pod restart count is a sumtotal of restart counts of individual containers		
              #within the pod. The restart count of a container is maintained by kubernetes		
              #itself in the form of a container label.		
              containerRestartCount = container['restartCount']		
              record['ContainerRestartCount'] = containerRestartCount
              containerStatus = container['state']
              # state is of the following form , so just picking up the first key name
              # "state": {
              #   "waiting": {
              #     "reason": "CrashLoopBackOff",
              #      "message": "Back-off 5m0s restarting failed container=metrics-server pod=metrics-server-2011498749-3g453_kube-system(5953be5f-fcae-11e7-a356-000d3ae0e432)"
              #   }
              # },
              # the below is for accounting 'NodeLost' scenario, where-in the containers in the lost node/pod(s) is still being reported as running
              if podReadyCondition == false
                record['ContainerStatus'] = "Unknown"
              else
                record['ContainerStatus'] = containerStatus.keys[0]
              end
              #TODO : Remove ContainerCreationTimeStamp from here since we are sending it as a metric
              #Picking up both container and node start time from cAdvisor to be consistent
              if containerStatus.keys[0] == "running"
                record['ContainerCreationTimeStamp'] = container['state']['running']['startedAt']
              end
              podRestartCount += containerRestartCount	
              records.push(record.dup) 
            end 
          else # for unscheduled pods there are no status.containerStatuses, in this case we still want the pod
            records.push(record) 
          end  #container status block end
          records.each do |record|
            if !record.nil?
              record['PodRestartCount'] = podRestartCount
              wrapper = {
                          "DataType"=>"KUBE_POD_INVENTORY_BLOB",
                          "IPName"=>"ContainerInsights",
                          "DataItems"=>[record.each{|k,v| record[k]=v}]
                        }
              eventStream.add(emitTime, wrapper) if wrapper
            end  
          end  
        end  #podInventory block end
        router.emit_stream(@tag, eventStream) if eventStream
        if telemetryFlush == true
          ApplicationInsightsUtility.sendHeartBeatEvent("KubePodInventory", @@ReplicasetControllerType)
          ApplicationInsightsUtility.sendMetricTelemetry("PodCount", podInventory['items'].length , {}, @@ReplicasetControllerType)
          ApplicationInsightsUtility.sendMetricTelemetry("ControllerCount", controllerSet.length , {}, @@ReplicasetControllerType)
          @@podTelemetryTimeTracker = DateTime.now.to_time.to_i
        end
        @@istestvar = ENV['ISTEST']
        if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp('true') == 0 && eventStream.count > 0)
          $log.info("kubePodInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
        end
      rescue  => errorStr
        $log.warn "Failed in parse_and_emit_record pod inventory: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr, @@ReplicasetControllerType)
      end #begin block end  
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
            $log.info("in_kube_podinventory::run_periodic @ #{Time.now.utc.iso8601}")
            enumerate
          rescue => errorStr
            $log.warn "in_kube_podinventory::run_periodic: enumerate Failed to retrieve pod inventory: #{errorStr}"
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr, @@ReplicasetControllerType)
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end

    def getServiceNameFromLabels(namespace, labels, serviceList)
      serviceName = ""
      begin
        if !labels.nil? && !labels.empty? 
          if( !serviceList.nil? && !serviceList.empty? && serviceList.key?("items") && !serviceList['items'].empty?)
            serviceList['items'].each do |item|
              found = 0
              if !item['spec'].nil? && !item['spec']['selector'].nil? && item['metadata']['namespace'] == namespace 
                selectorLabels = item['spec']['selector']
                if !selectorLabels.empty?
                  selectorLabels.each do |key,value|
                    if !(labels.select {|k,v| k==key && v==value}.length > 0)
                      break
                    end
                    found = found + 1
                  end
                end  
                if found == selectorLabels.length
                  return item['metadata']['name']
                end
              end  
            end
          end  
        end
      rescue  => errorStr
        $log.warn "Failed to retrieve service name from labels: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr, @@ReplicasetControllerType)
      end
      return serviceName
    end

  end # Kube_Pod_Input

end # module


