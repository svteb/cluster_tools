require "log"
require "./spec_helper"
require "../cluster_tools.cr"

describe "ClusterTools" do
  before_all do
    begin
      is_namespace_created =  KubectlClient::Create.namespace(ClusterTools.namespace)
      (is_namespace_created).should be_true
      Log.info { "#{ClusterTools.namespace} namespace created" }
    rescue e : KubectlClient::Create::AlreadyExistsError
      Log.info { "#{ClusterTools.namespace} namespace already exists on the Kubernetes cluster" }
    end
  end
  after_all do
    ClusterTools.uninstall
  end
  describe "install" do
    it "works" do
      (ClusterTools.install).should be_true
    end
  end

  describe "other_functions" do
    before_all do
      ClusterTools.install
    end
    it "pod_name",  do
      (/cluster-tools/ =~ ClusterTools.pod_name).should_not be_nil
    end
  end

end

