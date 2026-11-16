#!/bin/sh
# vg-fds.sh LOG: succeed if the valgrind log LOG (from --track-fds=yes)
# shows no descriptor open at exit but those the program inherited.
# valgrind reports "FILE DESCRIPTORS: <n> open (<m> inherited) at exit.",
# and one the program left open makes n greater than m, listing it below
# (valgrind 3.27.1, checked 2026-11-15). A log without the line fails.
awk '
  /FILE DESCRIPTORS: [0-9]+ open \([0-9]+ inherited\) at exit/ {
    for (i = 1; i < NF; i++) if ($i == "DESCRIPTORS:") { n = $(i + 1); m = $(i + 3) }
    sub(/^\(/, "", m); found = 1
  }
  END { exit !(found && n == m) }
' "$1"
