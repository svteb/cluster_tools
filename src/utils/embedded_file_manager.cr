module EmbeddedFileManager 
  macro cluster_tools
    CLUSTER_TOOLS = Base64.decode_string("{{ `cat ./tools/cluster-tools/manifest.yml | base64` }}")
  end
end
