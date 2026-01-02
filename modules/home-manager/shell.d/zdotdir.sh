export PATH="@gitPath@:$PATH"
if [ ! -d "$HOME/.config/zsh/.git" ]; then
  @gitBin@ clone --depth=1 https://github.com/nxmatic/zdotdir.git "$HOME/.config/zsh"
else
  @gitBin@ -C "$HOME/.config/zsh" pull --ff-only
fi
