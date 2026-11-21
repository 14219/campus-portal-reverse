# 安全策略

## 报告问题

如果你发现本文档或脚本可能导致**账号泄露、未授权访问、绕过计费**的问题
（例如某段描述实际上构成了可复制的越权方法），请不要开公开 Issue，改用 GitHub 的
[私密漏洞报告](https://docs.github.com/zh/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)（Security → Report a vulnerability）。

请在报告里说明：

- 涉及哪篇文章、哪一节或哪个脚本
- 为什么构成风险（可复现的最小描述即可，**不要附带真实账号或抓包数据**）
- 你建议的处理方式（删除 / 改写 / 加限制说明）

## 响应

- 3 个工作日内确认收到
- 7 个工作日内给出处理结论（改写、补充警示或移除）
- 处理完成后，如你同意，会在文档中致谢

## 不在范围内

- 学校 Portal / BRAS 系统本身的漏洞 —— 请直接联系学校网络中心
- 门户 SHA/RSA 加密方式的强弱评价（取决于各校配置，非本项目可控）
- 因使用者违反 [适用边界](README.md#适用边界与免责) 导致的问题

## 仓库自身的卫生

- 不接收含真实账号、密码、MAC、抓包文件或个人路径的 PR
- 发现历史提交里混入了真实凭证，会立即改写历史并强制推送，同时在此处记录
