for d in @dirs@; do
  if [ ! -d "$d" ]; then
    install -d -m 0755 -o @userName@ -g @group@ "$d"
  fi
done
