#!/usr/bin/env bash
case "$1" in
  *sername*) echo "${LAB_GIT_USER:-}" ;;
  *assword*) echo "${LAB_GIT_PASS:-}" ;;
  *) echo "" ;;
esac
