#!/bin/bash
# Report (do not kill) any emacs-wm test processes left running.
# Exit non-zero if there are any.  Run this after a session, or from a driver.
exec bash "$(dirname "$0")/cleanup-ours.sh" check
