# This sources every file ending in .zsh in the current directory,
# except for this plugin file itself.
for file in "$ZSH_CUSTOM/plugins/my-functions"/*.zsh; do
  # Check if the file is not the plugin file itself
  if [[ "$file" != *my-functions.plugin.zsh ]]; then
    source "$file"
  fi
done
