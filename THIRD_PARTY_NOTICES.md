# 第三方归属

## Stats 的 SMC 协议参考

SMC packet 结构及风扇 key 约定参考 [exelban/stats 的 SMC 实现](https://github.com/exelban/stats/blob/master/SMC/smc.swift)。其 MIT 许可全文保留在 [Sources/SMCController/Stats-MIT.txt](Sources/SMCController/Stats-MIT.txt)，构建脚本会将该文件复制到应用资源目录。

## 窗口切换

窗口切换使用公开 Apple API 独立实现。项目不包含 AltTab、iTab 或其他窗口切换工具的二进制。

## iFan 行为研究

[iFan 控制行为分析](docs/reverse-engineering/ifan-control.md) 记录了为兼容性研究得到的调用顺序与有限硬件观察。项目不分发 iFan 应用、资源 CLI、管理员服务、原始反编译产物或完整反汇编内容，也不依赖其服务执行调速。

本文件记录第三方参考与归属，不为 Mac Go 自有代码另行选择许可。
