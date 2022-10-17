module EmbeddedFileManager
  macro cluster_tools

    # When being used as a shard, the manifest directory is available within the shard in the lib directory.
    # When running `crystal spec` within project, refer to tools in repo root.
    CLUSTER_TOOLS = if File.exists?("./lib/cluster_tools/tools/cluster-tools/manifest.yml")
        File.read("./lib/cluster_tools/tools/cluster-tools/manifest.yml")
      else
        File.read("./tools/cluster-tools/manifest.yml")
      end

  end
end
