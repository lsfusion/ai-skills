# lsFusion AI skills

[Agent Skills](https://docs.claude.com/en/docs/claude-code/skills) for working with
[lsFusion](https://lsfusion.org), packaged as a Claude Code plugin and bundled with the
official **`ai.lsfusion.org` MCP server**.

## What's inside

| Skill | Purpose |
|-------|---------|
| **lsfusion-dev** | Set up, run, and verify lsFusion applications locally (Windows). Writing/editing `.lsf`, scaffolding, starting the app server, diagnosing startup/form issues. |
| **lsfusion-deploy** | Deploy an lsFusion app to a remote Linux server: provisioning, packaging the jar, systemd units, HTTPS via certbot, pulling the prod PostgreSQL DB locally. |
| **lsfusion-eval** | Run lsFusion code against a running server over HTTP (`/eval`, `/exec`, `/eval/action`) and inspect what's actually deployed. |

```
ai-skills/
├── .claude-plugin/
│   ├── marketplace.json     # marketplace manifest (repo root → /plugin marketplace add)
│   └── plugin.json          # plugin definition
├── .mcp.json                # bundles the ai.lsfusion.org MCP server
└── skills/
    ├── lsfusion-dev/
    ├── lsfusion-deploy/
    └── lsfusion-eval/
```

## Install in Claude Code (one command)

```
/plugin marketplace add lsfusion/ai-skills
/plugin install lsfusion-ai-skills
```

This installs all three skills **and** registers the `lsfusion-ai` MCP server
(`https://ai.lsfusion.org/mcp`). On first use Claude Code may prompt you to authenticate
with the server.

## Use the skills without the plugin

The `skills/` folder follows the open Agent Skills format, so it works anywhere:

- **Claude Code (manual):** copy a skill folder into `~/.claude/skills/` (global) or
  `.claude/skills/` (per project).
- **Claude.ai / Claude Desktop:** zip a skill folder and upload it under
  Settings → Capabilities → Skills.
- **Claude API / Agent SDK:** mount the skill folder into the agent's working directory.

## The MCP server in other tools

Bundling MCP via the plugin is a Claude Code feature. Elsewhere, add
`https://ai.lsfusion.org/mcp` manually:

- **Claude.ai / Desktop** — Settings → Connectors → add a custom connector.
- **ChatGPT** — connector settings.
- **Codex** — add an `[mcp_servers.lsfusion-ai]` section to `~/.codex/config.toml`.

## License

Apache-2.0
