run install -d -m 700 ~/.ssh/keys.d
run @rsync@ -avL \
  --chmod=u+w,go-r \
  --chown=$(id -un):$(id -gn) \
  @keysDir@/ ~/.ssh/keys.d/ || true
