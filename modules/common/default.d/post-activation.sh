HM_ACTIVATE="@hmActivationPackage@/activate"
if [ -n "$HM_ACTIVATE" ] && [ -x "$HM_ACTIVATE" ]; then
  echo "Running home-manager activation last for @userName@ ..."
  sudo -u @userName@ HOME="@userHome@" XDG_RUNTIME_DIR="@userHome@/.xdg" "$HM_ACTIVATE"
else
  echo "home-manager activation package missing for @userName@, skipping" >&2
fi
