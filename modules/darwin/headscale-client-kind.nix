# Darwin hosts always register with the `darwin` kind
# (tag:console,tag:darwin).  A host that needs something else
# overrides `ndh.tailnetClient.kind` in its own host profile.
{
  ndh.tailnetClient.kind = "darwin";
}
