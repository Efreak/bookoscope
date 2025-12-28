#!/bin/bash
set -eux;

# Accept Android licenses
yes | sdkmanager --licenses || true;

# Get dependencies without attempting to change Flutter channel
flutter --version;
flutter pub get;

# Clean previous builds
flutter clean || true;

# Create temporary keystore and signing properties inside workspace (idempotent)
export KEYSTORE_DIR=/workspace/tmp_keystore
mkdir -p "$KEYSTORE_DIR"
export KEYSTORE_PATH="$KEYSTORE_DIR/keystore.jks"
export KEY_ALIAS=tmpkey
export KEYSTORE_PASS=android
export KEY_PASS=android

# Only generate if not already present in this workspace (idempotent per-workspace)
if [ ! -f "$KEYSTORE_PATH" ]; then
  keytool -genkeypair -v \
    -keystore "$KEYSTORE_PATH" \
    -storepass "$KEYSTORE_PASS" \
    -keypass "$KEY_PASS" \
    -alias "$KEY_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Temporary, OU=Dev, O=Dev, L=Earth, S=State, C=US"
fi

# Create gradle.properties with signing config pointing to the temp keystore
echo 'storePassword=$KEYSTORE_PASS' > /workspace/tmp_keystore/keystore.properties
echo 'keyPassword=$KEY_PASS' >> /workspace/tmp_keystore/keystore.properties
echo 'keyAlias=$KEY_ALIAS' >> /workspace/tmp_keystore/keystore.properties
echo "storeFile=$KEYSTORE_PATH" >> /workspace/tmp_keystore/keystore.properties

# Create an isolated Gradle script to apply signing config at build time without mutating project files.
# We'll instruct Gradle via --init-script to apply this signing config.
INIT_GRADLE=/workspace/tmp_keystore/init-signing.gradle

cat > /workspace/tmp_keystore/signing.gradle <<'GRADLE'
allprojects {
  afterEvaluate { project ->
    if (project.hasProperty('android')) {
      def propsFile = rootProject.file('tmp_keystore/keystore.properties')
      if (propsFile.exists()) {
        def keystoreProps = new Properties()
        keystoreProps.load(new FileInputStream(propsFile))
        android {
          signingConfigs {
            tempConfig {
              storeFile file(keystoreProps['storeFile'])
              storePassword keystoreProps['storePassword']
              keyAlias keystoreProps['keyAlias']
              keyPassword keystoreProps['keyPassword']
            }
          }
          buildTypes {
            release {
              signingConfig signingConfigs.tempConfig
            }
          }
        }
      }
    }
  }
}
GRADLE

## Build release APK and app bundle
#flutter build apk --release --target-platform android-arm,android-arm64,android-x64 --build-number=1 --build-name=1.0.0;
#flutter build appbundle --release --build-number=1 --build-name=1.0.0 || true;

# Build release APK and AAB; pass --no-shrink to avoid R8 issues on some projects (safe default).
# Use init script so we don't need to alter android/app/build.gradle in the repo.
flutter build apk --release --no-shrink --build-number=1 --build-name=1.0.0 --target-platform android-arm64 || true
# If the above fails for target-platform, try default:
if [ $? -ne 0 ]; then
  flutter build apk --release --no-shrink --build-number=1 --build-name=1.0.0 || true
fi

# Build app bundle (recommended) using Gradle init script to apply signing without repo changes
# Locate the android gradle wrapper and run with init script
if [ -d /workspace/android ]; then
  (cd /workspace/android && \
    ./gradlew bundleRelease --no-daemon -g /root/.gradle -Dorg.gradle.jvmargs='-Xmx1536m' --init-script "$INIT_GRADLE" ) || true
fi

# Collect outputs
mkdir -p /workspace/build_output/apk
mkdir -p /workspace/build_output/aab
cp -v /workspace/build/app/outputs/flutter-apk/*.apk /workspace/build_output/apk/ 2>/dev/null || true
cp -v /workspace/build/app/outputs/bundle/release/*.aab /workspace/build_output/aab/ 2>/dev/null || true
# Also collect any Gradle-produced bundle outputs
cp -v /workspace/android/app/build/outputs/bundle/release/*.aab /workspace/build_output/aab/ 2>/dev/null || true
cp -v /workspace/android/app/build/outputs/apk/release/*.apk /workspace/build_output/apk/ 2>/dev/null || true

# Save the temp keystore and properties for debugging (throwaway)
mkdir -p /workspace/build_output/keystore
cp -v "$KEYSTORE_PATH" /workspace/build_output/keystore/ || true
cp -v /workspace/tmp_keystore/keystore.properties /workspace/build_output/keystore/ || true

echo 'Build finished. Artifacts are in ./build_output on the host.';
sleep 2;
# Keep container running briefly so logs are visible; then exit
tail -n +1 /workspace/build_output/* 2>/dev/null || true