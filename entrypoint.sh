#!/bin/sh
# Ensure the nextjs user can access the Docker socket.
# Runs as root, then drops to nextjs via su-exec.
if [ -S /var/run/docker.sock ]; then
  chmod 666 /var/run/docker.sock
fi

exec su-exec nextjs "$@"
