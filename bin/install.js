#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const green = (t) => `\x1b[32m${t}\x1b[0m`;
const yellow = (t) => `\x1b[33m${t}\x1b[0m`;
const red = (t) => `\x1b[31m${t}\x1b[0m`;
const dim = (t) => `\x1b[2m${t}\x1b[0m`;

const ok = (msg) => console.log(`  ${green("✓")} ${msg}`);
const warn = (msg) => console.log(`  ${yellow("!")} ${msg}`);
const fail = (msg) => console.log(`  ${red("✗")} ${msg}`);

const CLAUDE_DIR = path.join(process.env.HOME, ".claude");
const STATUSLINE_PATH = path.join(CLAUDE_DIR, "statusline.sh");
const SETTINGS_PATH = path.join(CLAUDE_DIR, "settings.json");
const SOURCE_PATH = path.resolve(__dirname, "statusline.sh");

const SETTINGS_ENTRY = {
  type: "command",
  command: 'bash "$HOME/.claude/statusline.sh"',
};

function checkDeps() {
  const required = ["jq", "curl", "git"];
  const missing = required.filter((cmd) => {
    try {
      execSync(`which ${cmd}`, { stdio: "ignore" });
      return false;
    } catch {
      return true;
    }
  });

  if (missing.length > 0) {
    fail(`Missing dependencies: ${missing.join(", ")}`);
    console.log(
      `\n  Install with: ${dim(`brew install ${missing.join(" ")}`)}`,
    );
    process.exit(1);
  }
}

function readSettings() {
  try {
    return JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf8"));
  } catch {
    return {};
  }
}

function writeSettings(settings) {
  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
}

function install() {
  console.log(`\n  ${dim("claude-statusline")}\n`);

  checkDeps();

  fs.mkdirSync(CLAUDE_DIR, { recursive: true });

  if (fs.existsSync(STATUSLINE_PATH)) {
    fs.copyFileSync(STATUSLINE_PATH, `${STATUSLINE_PATH}.bak`);
    warn("Backed up existing statusline.sh to statusline.sh.bak");
  }

  fs.copyFileSync(SOURCE_PATH, STATUSLINE_PATH);
  fs.chmodSync(STATUSLINE_PATH, 0o755);
  ok("Installed statusline.sh");

  const settings = readSettings();
  const current = JSON.stringify(settings.statusLine);
  const expected = JSON.stringify(SETTINGS_ENTRY);

  if (current !== expected) {
    settings.statusLine = SETTINGS_ENTRY;
    writeSettings(settings);
    ok("Updated settings.json");
  } else {
    ok("settings.json already configured");
  }

  console.log(`\n  ${green("Done!")} Restart Claude Code to see the new statusline.\n`);
}

function uninstall() {
  console.log(`\n  ${dim("claude-statusline --uninstall")}\n`);

  const bakPath = `${STATUSLINE_PATH}.bak`;

  if (fs.existsSync(bakPath)) {
    fs.copyFileSync(bakPath, STATUSLINE_PATH);
    fs.unlinkSync(bakPath);
    ok("Restored previous statusline.sh from backup");
  } else if (fs.existsSync(STATUSLINE_PATH)) {
    fs.unlinkSync(STATUSLINE_PATH);
    ok("Removed statusline.sh");
  } else {
    warn("No statusline.sh found");
  }

  if (fs.existsSync(SETTINGS_PATH)) {
    const settings = readSettings();
    if (settings.statusLine) {
      delete settings.statusLine;
      writeSettings(settings);
      ok("Removed statusLine from settings.json");
    }
  }

  console.log(`\n  ${green("Done!")} Restart Claude Code to use the default statusline.\n`);
}

// ── Main ──
if (process.argv.includes("--uninstall")) {
  uninstall();
} else {
  install();
}
