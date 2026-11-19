#!/bin/sh
# vg-errors.sh LOG: succeed if every error in the valgrind log LOG is a
# descriptor open at exit, which vg-fds.sh then judges. valgrind 3.27.1
# counts each descriptor --track-fds=yes reports in ERROR SUMMARY, so a
# program with Tasks, whose self-pipe stays open, would fail
# --error-exitcode with no memory error at all (checked 2026-11-18).
# A log without the summary fails. From pogeminilib's.
awk '
  /ERROR SUMMARY: [0-9]+ errors/ {
    for (i = 1; i < NF; i++) if ($i == "SUMMARY:") e = $(i + 1)
    found = 1
  }
  /Open (file descriptor|AF_)/ { fds++ }
  END { exit !(found && e == fds) }
' "$1"
