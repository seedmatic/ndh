# Darwin hosts always register with the `darwin` kind
# (tag:console,tag:darwin).  A host that needs something else
# overrides `ndh.headscaleClient.kind` in its own host profile.
{
  ndh.headscaleClient.kind = "darwin";
}
