require "kubectl_client"
require "docker_client"
require "log"
require "ecr"

module ClusterTools
  # Default installation namespace
  @@namespace = "cnf-testsuite"

  class ManifestTemplate
    def initialize
    end

    ECR.def_to_s("#{__DIR__}/src/templates/manifest.yml.ecr")
  end

  class ManifestHostNamespaceTemplate
    def initialize
    end

    ECR.def_to_s("#{__DIR__}/src/templates/manifest-host-pid.yml.ecr")
  end

  def self.change_namespace(name)
    @@namespace = name
  end

  def self.namespace
    @@namespace
  end

  def self.namespace!
    self.ensure_namespace_exists!
    @@namespace
  end

  def self.ensure_namespace_exists!
    namespaces = KubectlClient::Get.namespaces()
    namespace_array = namespaces["items"].as_a 

    Log.debug { "ClusterTools ensure_namespace_exists namespace_array: #{namespace_array}" }

    unless namespace_array.find{ |n| n.dig?("metadata", "name") == self.namespace }
      raise NamespaceDoesNotExistException.new("ClusterTools Namespace #{self.namespace} does not exist")
    end 

    true
  end

  def self.install(host_namespace = true)
    Log.info { "ClusterTools install" }
    if host_namespace
      File.write("cluster_tools.yml", ManifestHostNamespaceTemplate.new().to_s)
    else
      File.write("cluster_tools.yml", ManifestTemplate.new().to_s)
    end
    KubectlClient::Apply.file("cluster_tools.yml", namespace: self.namespace!)
    wait_for_cluster_tools
  end

  def self.uninstall(host_namespace = true)
    Log.info { "ClusterTools uninstall" }
    if host_namespace
      File.write("cluster_tools.yml", ManifestHostNamespaceTemplate.new().to_s)
    else
      File.write("cluster_tools.yml", ManifestTemplate.new().to_s)
    end

    KubectlClient::Delete.file("cluster_tools.yml", namespace: self.namespace!)
    #todo make this work with cluster-tools-host-namespace
    KubectlClient::Get.resource_wait_for_uninstall("Daemonset", "cluster-tools", namespace: self.namespace!)
  end

  def self.exec(cli : String)
    # todo change to get all pods, schedulable nodes is slow
    pods = KubectlClient::Get.pods_by_nodes(KubectlClient::Get.schedulable_nodes_list)
    pods = KubectlClient::Get.pods_by_label(pods, "name", "cluster-tools")

    cluster_tools_pod_name = pods[0].dig?("metadata", "name") if pods[0]?
    Log.info { "cluster_tools_pod_name: #{cluster_tools_pod_name}"}

    cmd = "-ti #{cluster_tools_pod_name} -- #{cli}"
    KubectlClient.exec(cmd, namespace: self.namespace!)
  end


  def self.exec_by_node_construct_cli(cli : String, node : JSON::Any)
    pods = KubectlClient::Get.pods_by_nodes([node])
    # pods = KubectlClient::Get.pods_by_label(pods, "name", "cluster-tools-k8s")
    pods = KubectlClient::Get.pods_by_label(pods, "name", "cluster-tools")

    cluster_tools_pod_name = pods[0].dig?("metadata", "name") if pods[0]?
    Log.debug { "cluster_tools_pod_name: #{cluster_tools_pod_name}"}

    full_cli = "-ti #{cluster_tools_pod_name} -- #{cli}"
    Log.debug { "ClusterTools exec full cli: #{full_cli}" }
    return full_cli
  end

  def self.exec_by_node(cli : String, nodeName : String)
    Log.info { "exec_by_node: Called with String" }

    nodes = KubectlClient::Get.nodes["items"].as_a

    node : JSON::Any | Nil
    node = nodes.find{ |n| n.dig?("metadata", "name") == nodeName }

    if node
      self.exec_by_node(cli, node)
    else
      ""
    end
  end
    

  def self.exec_by_node(cli : String, node : JSON::Any)
    Log.info { "exec_by_node: Called with JSON" }
    # todo change to get all pods, schedulable nodes is slow

    # pods_by_nodes internally use KubectlClient::Get.pods which uses --all-namespaces option.
    # So they do not have to be passed the namespace to perform operations.
    full_cli = exec_by_node_construct_cli(cli, node)
    exec = KubectlClient.exec(full_cli, namespace: self.namespace)
    Log.debug { "ClusterTools exec: #{exec}" }
    exec
  end

  def self.exec_by_node_bg(cli : String, node : JSON::Any)
    # todo change to get all pods, schedulable nodes is slow

    # pods_by_nodes internally use KubectlClient::Get.pods which uses --all-namespaces option.
    # So they do not have to be passed the namespace to perform operations.
    
    full_cli = exec_by_node_construct_cli(cli, node)
    Log.debug { "ClusterTools exec full cli: #{full_cli}" }
    exec = KubectlClient.exec_bg(full_cli, namespace: self.namespace)
    Log.debug { "ClusterTools exec: #{exec}" }
    exec
  end

  # todo make compatible with other runtimes
  def self.parse_container_id(container_id : String)
    Log.info { "parse_container_id container_id: #{container_id}" }
    if container_id =~ /containerd/
      container_id.gsub("containerd://", "")[0..13] 
    else
      container_id
    end
  end

  def self.node_pid_by_container_id(container_id, node) : String | Nil
    Log.info {"node_pid_by_container_id container_id: #{container_id}" }
    short_container_id = parse_container_id(container_id)
    inspect = ClusterTools.exec_by_node("crictl inspect #{short_container_id}", node)
    Log.debug {"node_pid_by_container_id inspect: #{inspect[:output]}" }
    if inspect[:status].success?
      pid = "#{JSON.parse(inspect[:output]).dig?("info", "pid")}"
    else
      Log.error {"container_id not found for: #{container_id}" }
      pid = nil
    end
    Log.info {"node_pid_by_container_id pid: #{pid}" }
    pid 
  end

  #each_container_by_resource(resource, namespace) do | container_id, container_pid_on_node, node, container_proctree_statuses, container_status|
  def self.all_containers_by_resource?(resource, namespace, only_container_pids : Bool, &block) 
		kind = resource["kind"].downcase
		case kind
		when  "deployment","statefulset","pod","replicaset", "daemonset"
			resource_yaml = KubectlClient::Get.resource(resource[:kind], resource[:name], resource[:namespace])
			pods = KubectlClient::Get.pods_by_resource(resource_yaml, resource[:namespace])
			pid_log_names  = [] of String
			pod_resp = pods.map do |pod|
				pod_name = pod.dig("metadata", "name")
				Log.info { "pod_name: #{pod_name}" }

				status = pod["status"]
				if status["containerStatuses"]?
						container_statuses = status["containerStatuses"].as_a
					Log.info { "container_statuses: #{container_statuses}" }
					Log.info { "pod_name: #{pod_name}" }
					nodes = KubectlClient::Get.nodes_by_pod(pod)
					Log.info { "nodes_by_resource done" }
					node = nodes.first # there should only be one node returned for one pod
					container_status_result = container_statuses.map do |container_status|
						container_name = container_status.dig("name")
						previous_process_type = "initial_name"
						prefix_container_id = container_status.dig("containerID").as_s
						container_id = prefix_container_id.gsub("containerd://", "")
						Log.info { "before ready containerStatuses container_id #{container_id}" }
						ready = container_status.dig("ready").as_bool
						if !ready
							Log.info { "container status: #{container_status} "}
							Log.info { "not ready! skipping: containerStatuses container_id #{container_id}" }
							false
							next
						end
						# next unless ready 
						Log.info { "containerStatuses container_id #{container_id}" }
						#get container id's pid on the node (different from inside the container)
						container_pid_on_node = "#{ClusterTools.node_pid_by_container_id(container_id, node)}"
						if container_pid_on_node.empty?
							Log.info { "no pid for (skipping): containerStatuses container_id #{container_id}" }
							false
							next
						end

						# next if pid.empty?
						Log.info { "node pid (should never be pid 1): #{container_pid_on_node}" }

						node_name = node.dig("metadata", "name").as_s
						Log.info { "node name : #{node_name}" }
						pids = if only_container_pids 
                                                         KernelIntrospection::K8s::Node.pids_by_container(container_id, node)
                                                       else
                                                         KernelIntrospection::K8s::Node.pids(node)
                                                       end
						Log.info { "parsed pids: #{pids}" }
						proc_statuses = KernelIntrospection::K8s::Node.all_statuses_by_pids(pids, node)

						container_proctree_statuses = KernelIntrospection::K8s::Node.proctree_by_pid(container_pid_on_node, node, proc_statuses)

						yield container_id, container_pid_on_node, node, container_proctree_statuses, container_status 
					end
          Log.info { "container_status_result.all?(true): #{container_status_result.all?(true)}" }
          container_status_result.all?(true)
        else
          false
        end
			end
      Log.info { "pod_resp.all?(true): #{pod_resp.all?(true)}" }                     
      pod_resp.all?(true)
    else
      true # non "deployment","statefulset","pod","replicaset", and "daemonset" dont have containers
		end
	end

  def self.wait_for_cluster_tools
    Log.info { "ClusterTools wait_for_cluster_tools" }
    KubectlClient::Get.resource_wait_for_install("Daemonset", "cluster-tools", namespace: self.namespace!, wait_count: 300)
    # KubectlClient::Get.resource_wait_for_install("Daemonset", "cluster-tools-k8s", namespace: self.namespace)
  end

  # https://windsock.io/explaining-docker-image-ids/
  # works on dockerhub and quay!
  # ex. kubectl exec -ti cluster-tools-ww9lg -- skopeo inspect docker://jaegertracing/jaeger-agent:1.28.0
  # Accepts org/image:tag or repo/org/image:tag
  # A content digest is an uncompressed digest, which is what Kubernetes tracks 
  def self.official_content_digest_by_image_name(image_name)
    Log.info { "official_content_digest_by_image_name: #{image_name}"}

    result = exec("skopeo inspect docker://#{image_name}")
    response = result[:output]
    if result[:status].success? && !response.empty?
      return JSON.parse(response)
    end
    JSON.parse(%({}))
  end

  def self.local_match_by_image_name(image_names : Array(String), nodes=KubectlClient::Get.nodes["items"].as_a )
    image_names.map{|x| local_match_by_image_name(x, nodes)}.flatten.find{|m|m[:found]==true}
  end
  def self.local_match_by_image_name(image_name, nodes=KubectlClient::Get.nodes["items"].as_a )
    Log.info { "local_match_by_image_name image_name: #{image_name}" }
    nodes = KubectlClient::Get.nodes["items"].as_a
    local_match_by_image_name(image_name, nodes)
  end

  def self.local_match_by_image_name(image_name, nodes : Array(JSON::Any))
    Log.info { "local_match_by_image_name image_name: #{image_name}" }

    match = Hash{:found => false, :digest => "", :release_name => ""}
    #todo get name of pod and match against one pod instead of getting all pods and matching them
    tag = KubectlClient::Get.container_tag_from_image_by_nodes(image_name, nodes)

    if tag
      Log.info { "container tag: #{tag}" }

      pods = KubectlClient::Get.pods_by_nodes(nodes)

      #todo container_digests_by_pod (use pod from previous image search) --- performance enhancement
      imageids = KubectlClient::Get.container_digests_by_nodes(nodes)
      resp = ClusterTools.official_content_digest_by_image_name(image_name + ":" + tag )
      sha_list = [{"name" => image_name, "manifest_digest" => resp["Digest"].as_s}]
      Log.info { "jaeger_pods sha_list : #{sha_list}"}
      match = DockerClient::K8s.local_digest_match(sha_list, imageids)
      Log.info { "local_match_by_image_name match : #{match}"}
    else
      Log.info { "local_match_by_image_name tag: #{tag} match : #{match}"}
      match[:found]=false
    end
    Log.info { "local_match_by_image_name match: #{match}" }
    match
  end

  def self.pod_name()
    KubectlClient::Get.pod_status("cluster-tools", namespace: self.namespace!).split(",")[0]
  end

  def self.pod_by_node(node)
    resource = KubectlClient::Get.resource("Daemonset", "cluster-tools", namespace: self.namespace!)
    pods = KubectlClient::Get.pods_by_resource(resource, namespace: self.namespace!)
    cluster_pod = pods.find do |pod|
      pod.dig("spec", "nodeName") == node
    end
    cluster_pod.dig("metadata", "name") if cluster_pod
  end


  def self.cluster_tools_pod_by_node(node_name)
    Log.info { "cluster_tools_pod_by_node node_name: #{node_name}" }
    cluster_tools_pod = self.pod_by_node(node_name)
  end
  
  class NamespaceDoesNotExistException < Exception
  end
end
