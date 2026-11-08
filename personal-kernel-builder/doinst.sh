config() {
  NEW="$1"
  OLD="$(dirname "$NEW")/$(basename "$NEW" .new)"
  # Keep the admin's file; drop the .new copy if it is identical
  if [ ! -r "$OLD" ]; then
    mv "$NEW" "$OLD"
  elif [ "$(md5sum < "$OLD")" = "$(md5sum < "$NEW")" ]; then
    rm "$NEW"
  fi
}

config etc/personal-kernel-builder/personal-kernel-builder.conf.new
config etc/logrotate.d/personal-kernel-builder.new
