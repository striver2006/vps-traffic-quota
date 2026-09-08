# CLAUDE.md

本文件为 vps-traffic-quota 仓库的项目专属规则，与全局 `~/.claude/CLAUDE.md` 叠加生效（本文件优先）。

## Commit 署名

- Commit message 末尾**只保留** `Edit by CZB` 一行签名。
- **禁止**在 commit message 中追加任何 AI 署名 trailer，包括但不限于：
  - `Co-Authored-By: Claude ...`
  - `Co-Authored-By: <任何 @anthropic.com 邮箱>`
  - `🤖 Generated with Claude Code`
- PR 描述同样禁止追加上述署名。

**为什么**：GitHub 的 Contributors 列表由 commit 的 author 与 `Co-Authored-By:` trailer 计算得出，
一旦历史里出现指向 `noreply@anthropic.com` 的 trailer，`claude` 就会被列为本仓库的贡献者，
且网页端没有任何移除入口 —— 只能改写历史 + force push 才能清掉。这里禁掉是为了不再制造这种麻烦。
