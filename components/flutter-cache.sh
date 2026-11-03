#!/bin/bash
# Every archive is checked before ANY cache extraction. Flutter's own downloader
# never receives these archives. Only a fully staged cache gets a byte receipt.
flutter_cache_install() (
  tool_x64 'Flutter engine' || exit 1
  local cache="$FLUTTER_DIR/bin/cache" owner stage key row kind path dest entry sha
  local -a keys
  mapfile -t keys < <(sed -n 's/^\(FLUTTER_CACHE_[A-Z_0-9]*\)=.*/\1/p' "$KIT_DIR/manifests/tool-versions.conf")
  (( ${#keys[@]} )) || exit 1
  owner=$BASHPID
  stage=$(tool_stage "$cache" precache "$owner") || exit 1
  trap 'rm -rf "$stage"' EXIT
  mkdir -p "$stage/cache" || exit 1
  for key in "${keys[@]}"; do
    row=${!key}; IFS='|' read -r kind path dest entry sha <<< "$row"
    path=${path//\{engine\}/$FLUTTER_ENGINE_REVISION}
    tool_fetch "https://storage.googleapis.com/$path" "$sha" "$stage/${key#FLUTTER_CACHE_}.$kind" || exit 1
  done
  for key in "${keys[@]}"; do
    row=${!key}; IFS='|' read -r kind path dest entry sha <<< "$row"
    mkdir -p "$stage/cache/$dest" || exit 1
    case "$kind" in
      zip) unzip -q -o "$stage/${key#FLUTTER_CACHE_}.$kind" -d "$stage/cache/$dest" || exit 1 ;;
      tgz) tar -xzf "$stage/${key#FLUTTER_CACHE_}.$kind" -C "$stage/cache/$dest" || exit 1 ;;
      file) cp "$stage/${key#FLUTTER_CACHE_}.$kind" "$stage/cache/$dest/$entry" || exit 1 ;;
      *) exit 1 ;;
    esac
    [[ -s "$stage/cache/$dest/$entry" ]] || exit 1
  done
  # Match GradleWrapper.updateInner; templates supply their own properties.
  rm -f "$stage/cache/artifacts/gradle_wrapper/gradle/wrapper/gradle-wrapper.properties" \
    "$stage/cache/artifacts/gradle_wrapper/NOTICE" || exit 1
  python3 -I "$KIT_DIR/components/flutter-cache.py" seal "$KIT_DIR" "$stage/cache" || exit 1
  # Each published directory is whole. The receipt is published last. A kill
  # between directories leaves an incomplete cache that the next pass retries.
  for dest in artifacts pkg; do
    mkdir -p "$stage/old-$dest" || exit 1
    tool_publish_dir "$stage/cache/$dest" "$cache/$dest" "$stage/old-$dest" || exit 1
  done
  for dest in "$stage/cache/"*; do
    [[ -f "$dest" && "${dest##*/}" != setup-kit-cache.json ]] || continue
    mv -f "$dest" "$cache/${dest##*/}" || exit 1
  done
  mv -f "$stage/cache/setup-kit-cache.json" "$cache/setup-kit-cache.json"
)
