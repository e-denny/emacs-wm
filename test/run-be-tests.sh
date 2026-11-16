#!/bin/bash
# Unit tests for the backend's pure parts and the Wayland codec.
#   test/run-be-tests.sh
set -u
cd "$(dirname "$0")/.." || exit 1
exec emacs -Q --batch -L lisp -L test -l test/be-tests.el \
     -f ert-run-tests-batch-and-exit
