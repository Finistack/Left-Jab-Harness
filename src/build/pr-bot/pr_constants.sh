#!/usr/bin/env bash
# pr_constants.sh — Shared constants for the PR bot scripts.
# Sourced by pr_router.sh and pr_heartbeat.sh.

# ADO "Build" policy type UUID. Gate on this to distinguish real build-validation
# policies from non-build blocking policies (e.g. "Require a merge strategy",
# type fa4e907d-…) that also report status="rejected". Without this filter the
# bot treats a non-build rejection as a failing build and loops forever (observed
# on PR #1376). Used in both the heartbeat's actionable-work check and the
# router's build-failure enrichment.
BUILD_POLICY_TYPE_ID="0609b952-1397-4640-95ec-e00a01b2c241"
