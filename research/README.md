# 研究资料与来源记录

本仓库提交整理后的 [研究报告](../docs/research/研究边界.md) 和 [公开上游来源记录](platform/transport-review-sources.json)。原始研究材料保留在分析工作区，由根目录 `.gitignore` 排除。

## 随仓库提供

- `docs/research/`：研究结论、样本版本与哈希、证据标识、观察范围和限制。
- `research/platform/transport-review-sources.json`：libwebrtc 上游 revision、所查文件的 URL/哈希及官方文档来源；不含上游源码副本。

## 仅保留在本地工作区

- `research/casement/`：REA 输出、符号、反汇编与片段、样本身份记录。
- `research/jump/`：REA 输出、符号、反汇编、Objective-C 映射及工具诊断。
- `research/platform/` 中其余文件：本机 SDK 信息、工具诊断和历次文档检查记录。

报告中的这些本地证据以文件路径或名称标注，不作为 GitHub 下载链接。克隆仓库不会取得它们；仅凭报告不能独立重放所有二进制分析步骤。实际运行时表现与性能仍需按 [验证计划](../docs/design/验证计划.md) 测量。

初始化仓库没有移动或删除本地原始材料，也没有发布应用安装包、完整反汇编或运行录屏。
