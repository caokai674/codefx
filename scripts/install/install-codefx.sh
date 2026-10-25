#!/bin/sh
# Safety stop: never remove an existing installation while releases are incomplete.
echo 'Codefx replacement is temporarily disabled pending verified release assets. Keep your existing Codex installation.' >&2
exit 1
