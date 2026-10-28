# 贡献指南

> 先说清楚：这是个人项目，作者是普通用户，不是职业开发者/律师；没有官方支持，也没有 SLA。

## 先读

- [`SUPPORT.md`](SUPPORT.md) — issue/PR 第一行写 `To: human` / `To: ai` / `To: either`；
- [`docs/第三方代码政策.md`](docs/第三方代码政策.md) — 引入他人代码的三道门槛；
- [`SECURITY.md`](SECURITY.md) — 安全问题走私密报告，不要开公开 issue；
- [`docs/PR审查清单.md`](docs/PR审查清单.md) — 我会按这份清单审你的 PR（一票否决项在里面，先看一眼省得白改）。

## 提交 PR 前

1. 跑 `selftest.ps1`（只读）与 `tools/check-secrets.ps1`；
2. 不要提交 `config.json`、`登录态\`、`backup-secret.json`、真实观看记录或截图；
3. 改动尽量小，一个 PR 只做一件事；
4. 新增第三方代码前先开 issue 确认许可，不要直接贴进来。

## 许可与署名

- 提交即表示你同意以 **GPL-3.0** 授权你的贡献；
- 请使用 `git commit -s` 添加 Developer Certificate of Origin（DCO）签名，表示你有权提交这段代码；
- 不要提交你无权授权的代码、图片或文档。

## 与 AI 协作

- AI 可以起草补丁、整理 issue，但合并与发布由人决定；
- AI 生成的代码同样要过 `check-secrets` 与人工 review；
- 不要让 AI 读取或上传 `登录态\`、`backup-secret.json`。
