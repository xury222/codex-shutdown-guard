# 分发与官方目录

本项目通过 [GitHub 仓库](https://github.com/xury222/codex-shutdown-guard) 和 [Releases](https://github.com/xury222/codex-shutdown-guard/releases) 分发源码及 Windows 安装包。1.1.3 清理已移除历史文件留下的读取占位，并为仍在读取或读取异常的记录注明任务归属。子代理和内部审批继续不单独阻止关机。完整 Windows 包继续提供双击安装与卸载窗口，单插件包用于单独管理插件目录。

GitHub 分发与 OpenAI 官方插件目录上架是两个独立流程；本项目尚未上架官方目录。

## 官方目录资格

官方支持个人开发者通过个人身份验证，以自己的名字发布。提交仍需归属 OpenAI Platform organization 和项目。[官方提交说明](https://developers.openai.com/plugins/deploy/submission)

本插件运行本地 stdio MCP，属于 Desktop-only。官方文档将本地 MCP 提交限定为获批合作伙伴，需由 OpenAI 代表确认资格，并将提交组织加入允许名单。个人身份验证不会自动取得此项资格。[Desktop-only 提交要求](https://developers.openai.com/plugins/deploy/desktop-only)

## 官方目录待准备资料

- 提交主体、身份验证，以及本地 MCP 允许名单资格。
- 可公开访问的 HTTPS 官网、支持、隐私政策和服务条款页面。
- 正式目录图标、名称及说明。
- 审核演示录像、5 个正向用例和 3 个负向用例；若增加登录功能，还需审核访问方式。
- 发布国家或地区、商业行为声明与版本说明。
- 源码及安装包采用的许可证和分发条件。

GitHub 安装包不标记为可直接提交官方审核；包内没有填写占位政策地址或发布声明。审核材料字段以 [官方提交说明](https://developers.openai.com/plugins/deploy/submission) 为准。