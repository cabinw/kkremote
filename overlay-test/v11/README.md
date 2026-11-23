# WindowOverlayProbe V11 — 多态状态语义切换（Live Connection States）

本目录是受控窗口视觉层原型 **V11**，验证“**遮罩配色与动效直接表达连接状态语义**”的设计思路：不靠文字弹窗也能一眼区分推流中、暂停中、重连握手、隐私保护四类实时态，并与底部控制胶囊的图标色、状态文案内核、毛玻璃底色实时联动平滑过渡。

## 四大连接状态

| 状态 | 参数 | 视觉特征 | 胶囊文案 |
| --- | --- | --- | --- |
| 正常推流中 | `--state live` | 天青-钴蓝-薄荷绿稳态顺时针低频呼吸，中心清透 | `远程控制中` / `推流受控中` |
| 临时暂停中 | `--state paused` | 暖琥珀金加厚静谧封边，慢呼吸几近静止，轻微暖色暂停感 | `暂停控制中` / `已暂停控制` |
| 网络重连中 | `--state reconnecting` | 冰青 + 暖珊瑚双色高频雷达扫描光弧 + 向内声纳涟漪 | `重连握手中` |
| 隐私保护盾 | `--state privacy` | 深紫靛 + 玫红警戒边，整窗铺设 45° 加密斜纹半透隐私帷幕 | `隐私保护中` |

## 交互方式

- **点击控制胶囊空白区**（文字或旋转标附近）：按 `live → paused → reconnecting → privacy` 顺次切换状态并平滑过渡（同时停止自动轮播）。
- **菜单栏 `▣ V11`**：支持直接选择四态（快捷键 `1`–`4`）或开启/关闭“四态自动轮播 (每 4.5 秒)”。
- **CLI 参数**：支持 `--state ...`、`--cycle`（每 4.5 秒自动轮播展示全四态）、`--collapsed` 与 `--always-expanded`。

## 运行方式

```bash
# 默认以四态轮播预览（最直观查看全部语义状态）
./test-window-overlay.sh --app PopAgent --cycle

# 指定固定某一种状态
./test-window-overlay.sh --app PopAgent --state paused
./test-window-overlay.sh --app PopAgent --state reconnecting
./test-window-overlay.sh --app PopAgent --state privacy
```
