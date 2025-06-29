#!/bin/sh
set -e

# Execute the Ruby action script
exec ruby /action/lib/action.rb "$@"