#!/usr/bin/env bash
# 建立持久的 self-signed code-signing 身分「anypaint-dev」，讓每次 build 的 .app 有穩定的
# Designated Requirement，使 macOS TCC（螢幕錄製）授權跨重建保留（ad-hoc 會退回 cdhash、每次失效）。
# 跑一次即可；之後 scripts/build_app.sh 自動偵測並使用。已在 macOS 26 + OpenSSL 3.x 實測跑通。
#
# 做法參考自本機既有可運作專案（Plainly）的 setup-cert.sh。
set -e

CERT_NAME="anypaint-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 需要 OpenSSL 3.x（macOS 內建 LibreSSL 不支援 -legacy）。優先 homebrew。
OPENSSL="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"

echo "=== 建立自簽 code-signing 身分：$CERT_NAME ==="

# 自簽 cert 依 PKI 政策不算「valid for codesigning」，find-identity 可能不列出；
# 因此用「憑證存在 + 實際試簽」來判斷，而非 find-identity。
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    probe="$(mktemp)"
    if codesign -s "$CERT_NAME" "$probe" >/dev/null 2>&1; then
        echo "✅ 身分已存在且 codesign 可用，無需重建。"
        rm -f "$probe"; exit 0
    fi
    rm -f "$probe"
    echo "⚠️  憑證在但 codesign 不能用，重新匯入。"
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; cd "$WORK"

# 1. RSA 金鑰 + 自簽 X.509，帶 codeSigning EKU（codesign 才認）
"$OPENSSL" req -new -x509 -newkey rsa:2048 -nodes \
    -keyout key.pem -out cert.pem -days 3650 \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

# 2. 打包 PKCS#12。OpenSSL 3.x 需 -legacy + -macalg sha1，否則 Apple Security 匯入報 MAC 失敗；
#    空密碼在 3.6+ 也會失敗，故用臨時密碼。
P12_PASS="anypaint-transient"
"$OPENSSL" pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem \
    -name "$CERT_NAME" -passout "pass:$P12_PASS" -legacy -macalg sha1

# 3. 匯入 login keychain，授權 codesign 使用私鑰
security import cert.p12 -k "$KEYCHAIN" -T /usr/bin/codesign -P "$P12_PASS"

# 4. 讓 codesign 用私鑰時不彈鑰匙圈存取視窗
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

# 4b. 設「程式碼簽署」信任（本機實測此步讓 find-identity 列出並使 codesign 穩定使用）
security add-trusted-cert -p codeSign -k "$KEYCHAIN" cert.pem >/dev/null 2>&1 || true

# 5. 實際試簽驗證
probe="$(mktemp)"
if codesign -s "$CERT_NAME" "$probe" 2>&1; then
    echo ""; echo "✅ 已匯入且 codesign 驗證成功。"
    codesign -dvv "$probe" 2>&1 | grep -E "Authority|Identifier" || true
    rm -f "$probe"
else
    rm -f "$probe"
    echo "⚠️  codesign 無法使用此身分。請開「鑰匙圈存取」，找到「$CERT_NAME」，"
    echo "   把其私鑰對 codesign 的存取設為『一律允許』。"
    exit 1
fi
echo ""; echo "下一步：./scripts/build_app.sh —— 會自動偵測並用此身分簽章。"
