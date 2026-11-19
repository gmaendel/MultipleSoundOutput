#!/bin/zsh
# Builds a Developer ID-signed, notarized release of MultipleSoundOutput.
#   scripts/release.sh            build, sign, notarize -> build/MultipleSoundOutput-<version>.zip
#   scripts/release.sh --publish  also create the GitHub release and update the Homebrew cask
#
# Needs a "Developer ID Application" certificate and a saved notarization login:
#   xcrun notarytool store-credentials MultipleSoundOutput --apple-id <Apple ID> --team-id <team ID>
# Override with DEVELOPER_ID=<identity name or SHA-1> and NOTARY_PROFILE=<profile name>.
# COMMIT_TRAILER="Key: value" adds a trailer to the cask update commit.
set -euo pipefail

cd "${0:A:h}/.."
APP_NAME=MultipleSoundOutput
REPO=gmaendel/MultipleSoundOutput
TAP=gmaendel/tap
CASK=multiplesoundoutput
NOTARY_PROFILE=${NOTARY_PROFILE:-MultipleSoundOutput}
PUBLISH=false
[[ "${1:-}" == "--publish" ]] && PUBLISH=true

if $PUBLISH; then
  # The release tag is made from the pushed commit, so the build must match it.
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes before publishing." >&2; exit 1; }
  git fetch --quiet origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || { echo "Push your commits before publishing." >&2; exit 1; }
fi

# Pick the identity by SHA-1: the same certificate can be in the keychain twice.
DEVELOPER_ID=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ {print $2; exit}')}
[[ -n "$DEVELOPER_ID" ]] || { echo "No Developer ID Application certificate found." >&2; exit 1; }

scripts/build.sh
APP="build/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/$APP_NAME-$VERSION.zip"

echo "Signing $APP_NAME $VERSION with Developer ID…"
# Re-signing without --entitlements also drops the debugging entitlement of the development build.
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict "$APP"

echo "Notarizing (usually a minute or two)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
STATUS=$(plutil -extract status raw -o - - <<< "$RESULT")
if [[ "$STATUS" != Accepted ]]; then
  xcrun notarytool log "$(plutil -extract id raw -o - - <<< "$RESULT")" --keychain-profile "$NOTARY_PROFILE" || true
  echo "Notarization failed: $STATUS" >&2
  exit 1
fi

# Staple the ticket so Gatekeeper accepts the app offline, then zip the stapled app.
xcrun stapler staple -q "$APP"
spctl --assess --type execute "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "Built $ZIP (notarized)"
echo "sha256 $SHA256"

$PUBLISH || exit 0

TAG="v$VERSION"
gh release create "$TAG" "$ZIP" --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "$APP_NAME $VERSION" --generate-notes
echo "Published https://github.com/$REPO/releases/tag/$TAG"

TAP_DIR=$(brew --repository "$TAP")
[[ -d "$TAP_DIR" ]] || brew tap "$TAP"
git -C "$TAP_DIR" pull --quiet --ff-only
CASK_FILE="$TAP_DIR/Casks/$CASK.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" "$CASK_FILE"
if git -C "$TAP_DIR" diff --quiet; then
  echo "Cask already at $VERSION"
else
  TRAILER_ARGS=()
  [[ -n "${COMMIT_TRAILER:-}" ]] && TRAILER_ARGS=(--trailer "$COMMIT_TRAILER")
  git -C "$TAP_DIR" commit --quiet -am "$CASK $VERSION" "${TRAILER_ARGS[@]}"
  git -C "$TAP_DIR" push --quiet
  echo "Updated $TAP/$CASK to $VERSION"
fi
