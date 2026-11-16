#!/bin/bash
# Unit tests for the configuration layer (commands, bindings, rules, loader).
#   test/run-config-test.sh
#
# Pure Elisp, no compositor: this is the suite that proves a config file can
# not silently bind a key to a command that does not exist.
set -u
cd "$(dirname "$0")/.." || exit 1
exec emacs -Q --batch -L lisp -L test -l test/config-tests.el \
     -f ert-run-tests-batch-and-exit
