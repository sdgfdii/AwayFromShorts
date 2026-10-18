#!/usr/bin/env bash
# 离线回归：不连手机、不需要 Android 运行时。
# 用法（Git Bash）：  bash test/run.sh
#
# 时间判定已经是参数化的（星期掩码 + 起止分钟），多套配置都在 GuardTest 里跑，
# 不需要再 sed 改常量重编第二份。
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${AFS_SDK:-C:/Users/nj/.afs-android/sdk}"
ANDROID_JAR="$SDK/platforms/android-34/android.jar"
[ -f "$ANDROID_JAR" ] || { echo "找不到 $ANDROID_JAR" >&2; exit 1; }

if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="$(dirname "$(dirname "$(command -v javac)")")"
  export JAVA_HOME
fi
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"
[ -f "$JAVAC" ] || JAVAC=javac
[ -f "$JAVA" ] || JAVA=java

SEP=";"
case "$(uname -s)" in
  Linux|Darwin) SEP=":" ;;
esac

OUT="build/test"
rm -rf "$OUT"
mkdir -p "$OUT"
find java test/java -name '*.java' > "$OUT/sources.txt"
"$JAVAC" -encoding UTF-8 -nowarn -source 8 -target 8 \
  -bootclasspath "$ANDROID_JAR" -classpath "$ANDROID_JAR" \
  -d "$OUT" @"$OUT/sources.txt" 2>&1 | grep -vE '^(warning|注意|Note)' || true

"$JAVA" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 \
  -cp "$ANDROID_JAR${SEP}$OUT" com.afs.guard.GuardTest
