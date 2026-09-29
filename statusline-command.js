#!/usr/bin/env node
// Claude Code statusLine script
// Shows: model | current directory | git branch/status | context usage
'use strict';

const { execSync } = require('child_process');
const path = require('path');

let input = '';
process.stdin.on('data', (chunk) => (input += chunk));
process.stdin.on('end', () => {
  let data;
  try {
    data = JSON.parse(input);
  } catch {
    data = {};
  }

  const RESET = '\x1b[0m';
  const DIM = '\x1b[2m';
  const CYAN = '\x1b[36m';
  const BLUE = '\x1b[34m';
  const GREEN = '\x1b[32m';
  const YELLOW = '\x1b[33m';
  const RED = '\x1b[31m';

  const model = data.model?.display_name || 'Claude';
  const cwd = data.workspace?.current_dir || data.cwd || '';
  const dir = cwd ? path.basename(cwd) : '?';

  const segments = [`${DIM}${CYAN}${model}${RESET}`, `${DIM}${BLUE}${dir}${RESET}`];

  // --- Git branch/status (only when inside a git repo) ---
  if (cwd) {
    try {
      execSync('git --no-optional-locks rev-parse --is-inside-work-tree', {
        cwd,
        stdio: 'ignore',
      });

      let branch = execSync('git --no-optional-locks branch --show-current', {
        cwd,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      }).trim();
      if (!branch) {
        // Detached HEAD — fall back to short SHA
        branch = execSync('git --no-optional-locks rev-parse --short HEAD', {
          cwd,
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'ignore'],
        }).trim();
      }

      const dirty =
        execSync('git --no-optional-locks status --porcelain', {
          cwd,
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'ignore'],
        }).trim().length > 0;

      if (branch) {
        const color = dirty ? RED : GREEN;
        segments.push(`${DIM}|${RESET} ${color}${branch}${dirty ? '*' : ''}${RESET}`);
      }
    } catch {
      // Not a git repo (or git unavailable) — skip this segment
    }
  }

  // --- Context window usage ---
  const used = data.context_window?.used_percentage;
  if (used != null) {
    const pct = Math.floor(used);
    const color = pct >= 80 ? RED : pct >= 50 ? YELLOW : GREEN;
    segments.push(`${DIM}|${RESET} ${color}ctx ${pct}%${RESET}`);
  }

  console.log(segments.join(' '));
});
