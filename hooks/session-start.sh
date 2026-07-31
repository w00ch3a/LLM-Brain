#!/usr/bin/env sh
# Never block a Claude session. The skill performs all project-specific reads.
[ "${LLM_BRAIN_PASSIVE:-1}" = "0" ] && exit 0
printf '%s\n' \
  'LLM-BRAIN AUTOMATIC USE CONTRACT: LLM-Brain is active infrastructure; only the user experience is passive. For each non-trivial project task, automatically use the llm-brain skill to resolve and retrieve relevant approved project memory before work, then capture the authorised closeout. Current source, governing instructions, explicit user direction and live proof outrank memory. Never auto-promote protected material. Do not require the user to name LLM-Brain.'
exit 0
