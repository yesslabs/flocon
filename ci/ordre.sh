#!/bin/sh
# Envoie une notification distribuée, comme le ferait macOS (verrouillage) ou le test (ordres --pilote).
# Usage : ci/ordre.sh com.apple.screenIsLocked    ou    ci/ordre.sh com.yessen.flocon.pilote chasse
osascript -l JavaScript -e 'function run(a){ObjC.import("Foundation");$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(a[0],a.length>1?$(a[1]):$(),$(),true)}' "$@"
