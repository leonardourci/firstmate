## Using your own subagents

You may hand side work to your harness's own subagents inside this task. You stay the owner: make the decisions, review every subagent result, and run the final verification yourself.

Use the cheapest model that fits the side job (Claude: Haiku 5.5, `haiku`; Codex: gpt-6-luna):

- Finding code: locating definitions, callers, usages, or mapping an area. Ask for a file:line list, not file dumps.
- Mechanical follow-through: applying an already-decided rename or import fix across many files. Review the diff yourself.
- Long output: summarizing test, build, or CI logs.
- Second opinion: for a risky diff, one subagent at your own model tier reviews it before you report done.

Never delegate the design decision, the root-cause conclusion, the final verification, or a push or merge.

Credentials are fine to delegate when the task needs them, under the same rules you follow: use only sources the brief or the captain named (a credentials file path, AWS Secrets Manager, 1Password, an MFA code channel), never print, log, or commit a value, and ask before reading any other source.
