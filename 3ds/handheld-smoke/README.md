# KKRemote 掌机启动与触摸测试

此程序在 New 3DS LL 上显示两屏文字。用触控笔每点一下下屏，上屏的 Taps 应增加一次，并显示这次的 X、Y 坐标。按 START 返回 Homebrew Launcher。程序无需连接 Mac Host，适合先验证无线部署、两块屏幕和本地输入。

## 构建

使用带有 libctru、3dsxtool 和 smdhtool 的 devkitPro 3ds-dev 环境，在本目录运行：

```sh
./build.sh
```

也可以用官方 devkitARM 容器在 Mac 上构建：

```sh
docker run --rm -v "$PWD:/src" -w /src \
    devkitpro/devkitarm@sha256:116afba8df8453961de2936ffab20dd441edf4d682856c1ec8b0e53d7ed0bbf5 sh build.sh
```

## 发到自己的 3DS

Mac 和掌机接入同一局域网。在 Homebrew Launcher 的应用列表按实体 Y 键，保持 Netloader 开启。在 Mac 上通过 devkitPro 的 3dslink 发送，参数替换成下屏显示的地址：

```sh
3dslink -a <掌机局域网地址> .build/KKRemote-Smoke.3dsx
```

以掌机上屏显示 KKRemote、下屏点按后计数增加为真机验证依据。[Homebrew Launcher 的 Netloader 文档](https://github.com/devkitPro/3ds-hbmenu#netloader)

## 真机记录

2026-11-21，在 New 3DS LL 的 Homebrew Launcher 中打开 Netloader，从 Mac 用 3dslink 发送测试程序。操作者确认上屏显示 KKRemote，点按下屏两次后上屏显示 Taps: 2。本次验证覆盖无线发送、程序启动、双屏显示和本地触摸计数。远端 Mac 窗口串流与触控回传另行验证。
