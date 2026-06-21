#!/bin/bash
# Resident watcher (launchd KeepAlive). Makes the menu bar icon track the Claude
# DESKTOP app, not just sessions: shows it the moment Claude.app opens (before any
# session) and quits it when Claude closes. The hook system has no "app launched"
# event, so this process is the only way to catch desktop open/close.
#
# Predicate: keep the icon up if EITHER the Claude desktop app is running OR a
# Claude Code session is active (the refcount file lifecycle.js maintains). That
# OR is why CLI sessions and the desktop app don't fight over the icon.

BUNDLE_ID="com.local.claudestatusbar"
EXEC="ClaudeStatusBar"
DESKTOP_ID="com.anthropic.claudefordesktop"
COUNT_FILE="$HOME/.claude/statusbar/sessions"

while true; do
  # lsappinfo is LaunchServices-aware: non-empty ASN iff the GUI app is running.
  desktop_open=""
  [ -n "$(lsappinfo find "bundleid=$DESKTOP_ID" 2>/dev/null)" ] && desktop_open=1

  sessions=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  case "$sessions" in (''|*[!0-9]*) sessions=0 ;; esac

  app_up=""
  pgrep -x "$EXEC" >/dev/null 2>&1 && app_up=1

  if [ -n "$desktop_open" ] || [ "$sessions" -gt 0 ]; then
    [ -z "$app_up" ] && open -g -b "$BUNDLE_ID" 2>/dev/null
  else
    [ -n "$app_up" ] && pkill -x "$EXEC" 2>/dev/null
  fi

  sleep 2
done
