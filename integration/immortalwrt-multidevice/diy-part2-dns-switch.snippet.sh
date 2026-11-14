# ── dns-switch 包源接入（仅 r68s）────────────────────────────────────────
# 走「包安装线」：源码进 package/，config 选中 → 固件自带该包，且在 apk 里
# 可见、可 apk del（卸载走 prerm 还原 DNS，不会卸个软件把网卸断）。
#
# 不走 files/ 覆盖线：两条线同时用会让同一批文件装两遍，apk 记录与 overlay 打架。
#
# 执行上下文同上：CWD=openwrt/，.config 是编译树根的，本段早于 make defconfig。
# 顺序很关键 —— 包源必须先把 .config 里的选中项落实，defconfig 才不会被丢掉。
#
# 为什么 clone 而不是把源码复制进本仓：包仓已是 public，clone 拿到就是发版那个
# tag，不会出现「固件里是旧版」；换版本只改 DNS_SWITCH_REF。
if [[ "${DEVICE_MODEL:-}" == "r68s" ]]; then
    DNS_SWITCH_REF="${DNS_SWITCH_REF:-v1.0.0}"
    DNS_SWITCH_REPO="${DNS_SWITCH_REPO:-https://github.com/2286927/luci-app-dns-switch.git}"
    DNS_SWITCH_DIR="package/luci-app-dns-switch"

    echo ">>> 接入 dns-switch 包源（${DNS_SWITCH_REF}）"
    rm -rf /tmp/dns-switch-src "$DNS_SWITCH_DIR"
    if git clone --depth 1 --branch "$DNS_SWITCH_REF" "$DNS_SWITCH_REPO" /tmp/dns-switch-src; then
        # 仓库根是 luci-app-dns-switch/ 再套一层 luci-app-dns-switch/，
        # 这里把内层提上来，落到标准形态 package/<name>/Makefile —— 保证能被扫到。
        mkdir -p "$DNS_SWITCH_DIR"
        cp -a /tmp/dns-switch-src/luci-app-dns-switch/. "$DNS_SWITCH_DIR"/
        rm -rf /tmp/dns-switch-src
    else
        echo "❌ 克隆 dns-switch 失败（${DNS_SWITCH_REPO} @ ${DNS_SWITCH_REF}）"
        exit 1
    fi

    if [ ! -f "$DNS_SWITCH_DIR/Makefile" ]; then
        echo "❌ dns-switch 包源结构不对，找不到 $DNS_SWITCH_DIR/Makefile"
        find "$DNS_SWITCH_DIR" -maxdepth 2 -name Makefile | head
        exit 1
    fi
    echo ">>> dns-switch 包源已就位: $(ls "$DNS_SWITCH_DIR" | tr '\n' ' ')"

    # 网页上传导致仓库里三个脚本是 644；luci.mk 用 cp -p 打包会原样带进固件，
    # 装上去 dns-switch 跑不起来、init 不执行，属「打包成功但装上就废」。
    for _ds_x in \
        "$DNS_SWITCH_DIR/root/usr/bin/dns-switch" \
        "$DNS_SWITCH_DIR/root/etc/init.d/dns-switch" \
        "$DNS_SWITCH_DIR/root/etc/uci-defaults/99-dns-switch"; do
        [ -f "$_ds_x" ] && chmod +x "$_ds_x"
    done
    echo ">>> dns-switch 执行位已补"

    # config 里选中它。先删可能并存的 not set 行，再幂等追加。
    if [ -f .config ]; then
        sed -i '/^# CONFIG_PACKAGE_luci-app-dns-switch is not set$/d' .config
        grep -qx 'CONFIG_PACKAGE_luci-app-dns-switch=y' .config \
            || echo 'CONFIG_PACKAGE_luci-app-dns-switch=y' >> .config
        if grep -qx 'CONFIG_PACKAGE_luci-app-dns-switch=y' .config; then
            echo "✅ dns-switch 已选中（CONFIG_PACKAGE_luci-app-dns-switch=y）"
        else
            echo "❌ CONFIG_PACKAGE_luci-app-dns-switch=y 写入 .config 失败"
            exit 1
        fi
    else
        echo "❌ 找不到 .config（CWD=$(pwd)），dns-switch 无法选中"
        exit 1
    fi
else
    echo ">>> 非 r68s 机型，跳过 dns-switch 接入"
fi
