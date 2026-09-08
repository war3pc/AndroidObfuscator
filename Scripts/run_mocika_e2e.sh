#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
ANDROID_SDK_DIRECTORY="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/Library/Android/sdk}}"

if [[ -n "${JAVA_HOME:-}" ]]; then
    JAVA_RUNTIME_HOME="${JAVA_HOME}"
elif [[ -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]]; then
    JAVA_RUNTIME_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
else
    JAVA_RUNTIME_HOME="$(/usr/libexec/java_home 2>/dev/null)"
fi

if [[ -n "${ANDROID_BUILD_TOOLS_VERSION:-}" ]]; then
    BUILD_TOOLS_DIRECTORY="${ANDROID_SDK_DIRECTORY}/build-tools/${ANDROID_BUILD_TOOLS_VERSION}"
else
    BUILD_TOOLS_DIRECTORY="$(find "${ANDROID_SDK_DIRECTORY}/build-tools" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
        | /usr/bin/sort -V \
        | /usr/bin/tail -n 1)"
fi

if [[ -n "${ANDROID_PLATFORM_VERSION:-}" ]]; then
    ANDROID_PLATFORM_JAR="${ANDROID_SDK_DIRECTORY}/platforms/${ANDROID_PLATFORM_VERSION}/android.jar"
else
    ANDROID_PLATFORM_JAR="$(find "${ANDROID_SDK_DIRECTORY}/platforms" -mindepth 2 -maxdepth 2 -name android.jar -print 2>/dev/null \
        | /usr/bin/sort -V \
        | /usr/bin/tail -n 1)"
fi

for required_file in \
    "${JAVA_RUNTIME_HOME}/bin/javac" \
    "${JAVA_RUNTIME_HOME}/bin/jar" \
    "${JAVA_RUNTIME_HOME}/bin/keytool" \
    "${BUILD_TOOLS_DIRECTORY}/aapt" \
    "${BUILD_TOOLS_DIRECTORY}/d8" \
    "${BUILD_TOOLS_DIRECTORY}/apksigner" \
    "${BUILD_TOOLS_DIRECTORY}/zipalign" \
    "${ANDROID_PLATFORM_JAR}"; do
    if [[ ! -e "${required_file}" ]]; then
        echo "缺少 E2E 依赖：${required_file}" >&2
        exit 1
    fi
done

BUILD_TOOLS_VERSION_NAME="${BUILD_TOOLS_DIRECTORY:t}"
BUILD_TOOLS_MAJOR="${BUILD_TOOLS_VERSION_NAME%%.*}"
if [[ "${BUILD_TOOLS_MAJOR}" == <-> ]] && (( BUILD_TOOLS_MAJOR >= 35 )); then
    ZIPALIGN_PAGE_ARGUMENTS=(-P 16)
else
    ZIPALIGN_PAGE_ARGUMENTS=(-p)
fi

FIXTURE_DIRECTORY="${PROJECT_DIRECTORY}/Tests/Fixtures/MocikaE2E"
ENGINE_DIRECTORY="${PROJECT_DIRECTORY}/Resources/MocikaShield"
RUN_DIRECTORY="$(mktemp -d /tmp/android-obfuscator-mocika-e2e.XXXXXX)"
APKTOOL_JAVA_HOME="${RUN_DIRECTORY}/apktool-java-home"
E2E_SUCCEEDED=0

cleanup_failed_run() {
    if [[ "${E2E_SUCCEEDED}" != "1" && -n "${RUN_DIRECTORY:-}" && -d "${RUN_DIRECTORY}" ]]; then
        rm -rf "${RUN_DIRECTORY}"
    fi
}
trap cleanup_failed_run EXIT INT TERM

mkdir -p \
    "${RUN_DIRECTORY}/classes" \
    "${RUN_DIRECTORY}/dex" \
    "${APKTOOL_JAVA_HOME}/Library/apktool/framework"
cp \
    "${ANDROID_PLATFORM_JAR}" \
    "${APKTOOL_JAVA_HOME}/Library/apktool/framework/1.apk"

"${JAVA_RUNTIME_HOME}/bin/javac" \
    -source 8 \
    -target 8 \
    -d "${RUN_DIRECTORY}/classes" \
    "${FIXTURE_DIRECTORY}/src/dev/androidobfuscator/fixture/Fixture.java"

"${JAVA_RUNTIME_HOME}/bin/jar" \
    --create \
    --file "${RUN_DIRECTORY}/fixture.jar" \
    -C "${RUN_DIRECTORY}/classes" .

JAVA_HOME="${JAVA_RUNTIME_HOME}" "${BUILD_TOOLS_DIRECTORY}/d8" \
    --min-api 21 \
    --output "${RUN_DIRECTORY}/dex" \
    "${RUN_DIRECTORY}/fixture.jar"

"${BUILD_TOOLS_DIRECTORY}/aapt" package \
    -f \
    -M "${FIXTURE_DIRECTORY}/AndroidManifest.xml" \
    -S "${FIXTURE_DIRECTORY}/res" \
    -I "${ANDROID_PLATFORM_JAR}" \
    -F "${RUN_DIRECTORY}/input-unsigned-unaligned.apk"

(cd "${RUN_DIRECTORY}/dex" && /usr/bin/zip -q -j "${RUN_DIRECTORY}/input-unsigned-unaligned.apk" classes.dex)

"${BUILD_TOOLS_DIRECTORY}/zipalign" \
    -f \
    "${ZIPALIGN_PAGE_ARGUMENTS[@]}" \
    4 \
    "${RUN_DIRECTORY}/input-unsigned-unaligned.apk" \
    "${RUN_DIRECTORY}/input-unsigned.apk"

"${JAVA_RUNTIME_HOME}/bin/keytool" \
    -genkeypair \
    -noprompt \
    -keystore "${RUN_DIRECTORY}/fixture.p12" \
    -storetype PKCS12 \
    -storepass android-obfuscator-test-only \
    -keypass android-obfuscator-test-only \
    -alias fixture \
    -keyalg RSA \
    -keysize 2048 \
    -validity 30 \
    -dname "CN=Android Obfuscator E2E,OU=Test,O=Local,L=Local,ST=Local,C=CN"

JAVA_HOME="${JAVA_RUNTIME_HOME}" "${BUILD_TOOLS_DIRECTORY}/apksigner" sign \
    --ks "${RUN_DIRECTORY}/fixture.p12" \
    --ks-type PKCS12 \
    --ks-key-alias fixture \
    --ks-pass pass:android-obfuscator-test-only \
    --key-pass pass:android-obfuscator-test-only \
    --out "${RUN_DIRECTORY}/input-signed.apk" \
    "${RUN_DIRECTORY}/input-unsigned.apk"

JAVA_HOME="${JAVA_RUNTIME_HOME}" "${BUILD_TOOLS_DIRECTORY}/apksigner" verify \
    --verbose \
    --print-certs \
    "${RUN_DIRECTORY}/input-signed.apk" \
    | /usr/bin/tee "${RUN_DIRECTORY}/input-signature.txt"

JAVA_HOME="${JAVA_RUNTIME_HOME}" \
JAVA_TOOL_OPTIONS="-Duser.home=${APKTOOL_JAVA_HOME}" \
"${ENGINE_DIRECTORY}/bin/shield" protect \
    -i "${RUN_DIRECTORY}/input-signed.apk" \
    -o "${RUN_DIRECTORY}/protected-unsigned.apk" \
    --resources "${ENGINE_DIRECTORY}/resources/resources.zip" \
    --environment-policy compatible \
    --json-progress

JAVA_HOME="${JAVA_RUNTIME_HOME}" "${BUILD_TOOLS_DIRECTORY}/apksigner" sign \
    --ks "${RUN_DIRECTORY}/fixture.p12" \
    --ks-type PKCS12 \
    --ks-key-alias fixture \
    --ks-pass pass:android-obfuscator-test-only \
    --key-pass pass:android-obfuscator-test-only \
    --out "${RUN_DIRECTORY}/protected-signed.apk" \
    "${RUN_DIRECTORY}/protected-unsigned.apk"

JAVA_HOME="${JAVA_RUNTIME_HOME}" "${BUILD_TOOLS_DIRECTORY}/apksigner" verify \
    --verbose \
    --print-certs \
    "${RUN_DIRECTORY}/protected-signed.apk" \
    | /usr/bin/tee "${RUN_DIRECTORY}/output-signature.txt"

INPUT_CERTIFICATE_SHA256="$(/usr/bin/awk -F ': ' \
    'tolower($1) ~ /certificate sha-256 digest$/ { print toupper($2) }' \
    "${RUN_DIRECTORY}/input-signature.txt" \
    | /usr/bin/sort \
    | /usr/bin/uniq)"
OUTPUT_CERTIFICATE_SHA256="$(/usr/bin/awk -F ': ' \
    'tolower($1) ~ /certificate sha-256 digest$/ { print toupper($2) }' \
    "${RUN_DIRECTORY}/output-signature.txt" \
    | /usr/bin/sort \
    | /usr/bin/uniq)"
if [[ -z "${INPUT_CERTIFICATE_SHA256}" || "${INPUT_CERTIFICATE_SHA256}" != "${OUTPUT_CERTIFICATE_SHA256}" ]]; then
    echo "输入与加固 APK 的签名证书 SHA-256 不一致" >&2
    exit 1
fi

"${BUILD_TOOLS_DIRECTORY}/zipalign" \
    -c \
    "${ZIPALIGN_PAGE_ARGUMENTS[@]}" \
    -v \
    4 \
    "${RUN_DIRECTORY}/protected-signed.apk"

JAVA_HOME="${JAVA_RUNTIME_HOME}" "${ENGINE_DIRECTORY}/bin/shield" check-apk \
    "${RUN_DIRECTORY}/protected-signed.apk"

/usr/bin/unzip -p "${RUN_DIRECTORY}/protected-signed.apk" classes.dex \
    | /usr/bin/grep -a -q MSHD

for abi in armeabi-v7a arm64-v8a x86 x86_64; do
    alias_count="$(/usr/bin/unzip -Z1 "${RUN_DIRECTORY}/protected-signed.apk" \
        | /usr/bin/awk -v abi="${abi}" '$0 ~ "^lib/" abi "/libmodule[a-z]+\\.so$" { count++ } END { print count + 0 }')"
    if [[ "${alias_count}" != "1" ]]; then
        echo "${abi} 未包含唯一的任务级 Native 别名库" >&2
        exit 1
    fi
done

if /usr/bin/unzip -Z1 "${RUN_DIRECTORY}/protected-signed.apk" \
    | /usr/bin/grep -q '/libmocikashield\.so$'; then
    echo "加固结果仍包含固定名称 libmocikashield.so" >&2
    exit 1
fi

E2E_SUCCEEDED=1
echo "E2E_OUTPUT=${RUN_DIRECTORY}"
