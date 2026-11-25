#!/bin/bash
if pkill -x LockscreenDah 2>/dev/null; then
  echo "Lockscreen Dah stopped"
else
  echo "Lockscreen Dah is not running"
fi
