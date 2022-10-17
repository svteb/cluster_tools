module EmbeddedFileManager
  macro cluster_tools
    CLUSTER_TOOLS = if ENV["USE_MANIFEST_SPECS_DIRECTORY"]?
        File.read("./tools/cluster-tools/manifest.yml")
      else
        File.read("./lib/cluster_tools/tools/cluster-tools/manifest.yml")
      end
  end
end
