#!/usr/bin/env bash
# ==============================================================================
# GUARD_RAILS.SH - PreToolUse Security Gate for Claude Code
# ==============================================================================
# Rules:
# 1. Must be lightning-fast (no linting, no compiling).
# 2. Must use 'exit 2' to explicitly abort a tool execution in Claude Code.
# 3. Must use 'exit 0' to allow the tool to safely execute.
# ==============================================================================

# Capture the command and arguments Claude is trying to run
COMMAND_ARGS="$*"

# ------------------------------------------------------------------------------
# 1. BLOCK SENSITIVE FILE ACCESS (Credential/Token leaks)
# ------------------------------------------------------------------------------
# Prevents Claude from accidentally reading, writing, or catting secrets
if [[ "$COMMAND_ARGS" =~ \.env|\.git/config|id_rsa|id_ed25519|secrets\.yaml|credentials ]]; then
    echo "❌ SECURITY DENIED: Claude is strictly blocked from accessing environment secrets or SSH keys."
    exit 2
fi

# ------------------------------------------------------------------------------
# 2. BLOCK DESTRUCTIVE GIT OPERATIONS
# ------------------------------------------------------------------------------
# Prevents Claude from altering repository history or force-pushing over your work
if [[ "$COMMAND_ARGS" =~ "git push" && "$COMMAND_ARGS" =~ "--force" || "$COMMAND_ARGS" =~ "git push" && "$COMMAND_ARGS" =~ "-f" ]]; then
    echo "❌ SECURITY DENIED: Force-pushing to remote repositories is disabled for AI autonomy."
    exit 2
fi

if [[ "$COMMAND_ARGS" =~ "git reset --hard" && "$COMMAND_ARGS" =~ "origin/" ]]; then
    echo "❌ SECURITY DENIED: Destructive hard resets against origin are blocked."
    exit 2
fi

if [[ "$COMMAND_ARGS" =~ "git commit" && "$COMMAND_ARGS" =~ "--no-verify" || "$COMMAND_ARGS" =~ "git commit" && "$COMMAND_ARGS" =~ " -n" || "$COMMAND_ARGS" =~ "git push" && "$COMMAND_ARGS" =~ "--no-verify" || "$COMMAND_ARGS" =~ "git push" && "$COMMAND_ARGS" =~ " -n" ]]; then
    echo "❌ SECURITY DENIED: Git verification bypass flags (-n / --no-verify) are prohibited."
    exit 2
fi

# ------------------------------------------------------------------------------
# 3. BLOCK DANGEROUS SYSTEM COMMANDS
# ------------------------------------------------------------------------------
# Catches accidents like raw disk wipes or recursive root deletions
if [[ "$COMMAND_ARGS" =~ "rm -rf /" || "$COMMAND_ARGS" =~ "rm -rf ." && ! "$COMMAND_ARGS" =~ "rm -rf .mypy_cache" && ! "$COMMAND_ARGS" =~ "rm -rf .pytest_cache" ]]; then
    echo "❌ SECURITY DENIED: Recursive root or sweeping current-directory deletions are blocked."
    exit 2
fi

# ------------------------------------------------------------------------------
# 4. PROTECT THE VALIDATION INTEGRITY
# ------------------------------------------------------------------------------
# Prevents Claude from disabling your quality gates by deleting the script folder
if [[ "$COMMAND_ARGS" =~ "rm" && "$COMMAND_ARGS" =~ "scripts" || "$COMMAND_ARGS" =~ "rm" && "$COMMAND_ARGS" =~ ".claude" ]]; then
    echo "❌ SECURITY DENIED: You cannot delete or tamper with the configuration or script rules."
    exit 2
fi

# Safe to proceed
exit 0
