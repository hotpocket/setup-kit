#!/usr/bin/env python3
"""Independent read-only checks. Never imports installer probes or lib.sh."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import urllib.parse


class Drift(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Drift(message)


def executable(path):
    require(path.is_file() and path.stat().st_size > 0 and os.access(path, os.X_OK), f"missing executable {path}")


def text_is(path, expected):
    require(path.read_text().strip() == expected, f"drifted receipt {path}")


def version(path, expected):
    executable(path)
    result = subprocess.run([str(path), "--version"], capture_output=True, text=True, timeout=30)
    require(result.returncode == 0 and re.search(expected, result.stdout + result.stderr), f"version drift {path}")


def content(directory, entry):
    receipt = json.loads((directory / '.setup-kit-executables.json').read_text())
    expected = receipt.get(entry)
    require(isinstance(expected, str) and re.fullmatch('[a-f0-9]{64}', expected), 'missing executable digest')
    actual = hashlib.sha256((directory / entry).read_bytes()).hexdigest()
    require(actual == expected, f'corrupt executable {directory / entry}')


def properties(path):
    return dict(line.split("=", 1) for line in
                (line.strip() for line in path.read_text().splitlines())
                if "=" in line and not line.startswith(("#", "!")))


def prop(path, key, expected=None):
    values = {k.strip(): v.strip() for k, v in properties(path).items()}
    require(key in values and bool(values[key]), f"incomplete Android receipt {path}")
    if expected is not None:
        require(values[key] == expected, f"Android revision drift {path}")


def main():
    tool, kit, root, git_home = sys.argv[1:]
    kit, root, home = Path(kit), Path(root), Path.home()
    pins = {}
    for line in (kit / "manifests/tool-versions.conf").read_text().splitlines():
        if re.match(r"^[A-Z_0-9]+=", line):
            key, value = line.split("=", 1)
            pins[key] = shlex.split(value)[0]
    if tool == "uv":
        for name in ("uv", "uvx"):
            version(home / ".local/bin" / name, rf"^{name} {re.escape(pins['UV_VERSION'])}(?:\s|$)")
    elif tool == "blender":
        directory = home / f".local/opt/blender-{pins['BLENDER_VERSION']}-linux-x64"
        binary = directory / "blender"
        version(binary, rf"^Blender {re.escape(pins['BLENDER_VERSION'])} LTS(?:\s|$)")
        require((home / ".local/bin/blender").resolve() == binary.resolve(), "Blender launcher drift")
        executable(directory / (pins['BLENDER_VERSION'].rsplit('.', 1)[0] + "/python/bin/python" + pins['BLENDER_PYTHON_VERSION']))
    elif tool == "flutter_headless":
        flutter, sdk = home / "development/flutter", home / "Android/Sdk"
        executable(flutter / "bin/flutter")
        revision = subprocess.check_output(["git", "-C", str(flutter), "rev-parse", "HEAD"], text=True).strip()
        require(revision == pins['FLUTTER_REVISION'], "Flutter source revision drift")
        cache = flutter / "bin/cache"
        # Check the complete release bootstrap independently, before executing Dart.
        release = json.loads((flutter / '.setup-kit-release.json').read_text())
        release_keys = ('FLUTTER_VERSION', 'FLUTTER_REVISION', 'FLUTTER_DART_VERSION',
                        'FLUTTER_ENGINE_REVISION', 'FLUTTER_RELEASE_URL', 'FLUTTER_RELEASE_SHA256')
        require(release.get('schema') == 1 and release['pins'] == {k: pins[k] for k in release_keys},
                'Flutter release archive drift')
        entries = {'bin/flutter', 'bin/dart', 'bin/cache/flutter_tools.snapshot',
                   'bin/cache/flutter_tools.stamp', 'bin/cache/engine-dart-sdk.stamp',
                   'packages/flutter_tools/pubspec.yaml', 'packages/flutter_tools/pubspec.lock',
                   'packages/flutter_tools/.dart_tool/package_config.json'}
        for directory in ('bin/internal', 'bin/cache/dart-sdk', '.setup-kit-pub-cache', '.pub-preload-cache'):
            entries.update(p.relative_to(flutter).as_posix() for p in (flutter / directory).rglob('*') if p.is_file())
        require(set(release['files']) == entries, 'Flutter bootstrap file inventory drift')
        package_file = flutter / 'packages/flutter_tools/.dart_tool/package_config.json'
        package_config = json.loads(package_file.read_text())
        require(package_config.get('configVersion') == 2 and package_config.get('packages'),
                'missing offline Flutter package configuration')
        for package in package_config['packages']:
            uri = urllib.parse.urlsplit(package['rootUri'])
            directory = (package_file.parent / urllib.parse.unquote(uri.path)).resolve()
            require(not uri.scheme and not uri.netloc and not uri.path.startswith('/') and
                    directory.is_relative_to(flutter.resolve()) and (directory / 'pubspec.yaml').is_file(),
                    'Flutter Pub source missing or outside verified release')
        executable(cache / 'dart-sdk/bin/dart')
        require((cache / 'flutter_tools.snapshot').stat().st_size > 0, 'missing Flutter tool snapshot')
        text_is(cache / 'flutter_tools.stamp', pins['FLUTTER_REVISION'] + ':')
        require((flutter / 'packages/flutter_tools/pubspec.yaml').stat().st_mtime_ns <=
                (flutter / 'packages/flutter_tools/pubspec.lock').stat().st_mtime_ns,
                'Flutter sources would trigger Pub bootstrap')
        for name, expected in release['files'].items():
            path = flutter / name
            with path.open('rb') as stream:
                actual = hashlib.file_digest(stream, 'sha256').hexdigest()
            require(actual == expected['sha256'], f'corrupt Flutter bootstrap {path}')
            if expected['executable']:
                executable(path)
        text_is(cache / "engine-dart-sdk.stamp", pins['FLUTTER_ENGINE_REVISION'])
        version(cache / "dart-sdk/bin/dart", rf"Dart SDK version: {re.escape(pins['FLUTTER_DART_VERSION'])}(?:\s|$)")
        metadata = json.loads((cache / "flutter.version.json").read_text())
        require(metadata.get('frameworkVersion') == pins['FLUTTER_VERSION'] and
                metadata.get('dartSdkVersion') == pins['FLUTTER_DART_VERSION'], "Flutter/Dart metadata drift")
        text_is(cache / "setup-kit-android.complete", pins['FLUTTER_REVISION'] + ':' + pins['FLUTTER_RELEASE_SHA256'])
        # Independent of the installer's cache probe: validate pinned archive
        # identity, required entries, stamps, and all sealed payload bytes.
        receipt = json.loads((cache / 'setup-kit-cache.json').read_text())
        require(receipt['pins'] == {k: v for k, v in pins.items() if k.startswith('FLUTTER_')}, 'Flutter archive pins drift')
        require(bool(receipt['files']), 'empty Flutter cache receipt')
        for key, row in pins.items():
            if key.startswith('FLUTTER_CACHE_'):
                _, _, destination, entry, _ = row.split('|')
                require((Path(destination) / entry).as_posix().removeprefix('./') in receipt['files'], 'missing Flutter artifact receipt')
        for name, value in receipt['files'].items():
            path = cache / name
            with path.open('rb') as stream:
                actual = hashlib.file_digest(stream, 'sha256').hexdigest()
            require(actual == value['sha256'], f'corrupt Flutter artifact {path}')
            if value['executable']:
                executable(path)
        for stamp in ('android-sdk', 'android-internal-build-artifacts', 'flutter_sdk', 'font-subset', 'engine_stamp'):
            text_is(cache / (stamp + '.stamp'), pins['FLUTTER_ENGINE_REVISION'])
        text_is(cache / 'material_fonts.stamp', pins['FLUTTER_FONTS_VERSION'])
        text_is(cache / 'gradle_wrapper.stamp', pins['FLUTTER_GRADLE_VERSION'])
        executable(sdk / 'platform-tools/adb')
        executable(sdk / f"build-tools/{pins['ANDROID_BUILD_TOOLS']}/aapt2")
        android_jar = sdk / f"platforms/{pins['ANDROID_PLATFORM']}/android.jar"
        require(android_jar.is_file() and android_jar.stat().st_size > 0, 'missing Android platform payload')
        executable(sdk / f"ndk/{pins['ANDROID_NDK']}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang")
        executable(root / "usr/lib/jvm/java-21-openjdk-amd64/bin/java")
        executable(sdk / "cmdline-tools/latest/bin/sdkmanager")
        require((sdk / "cmdline-tools/latest").resolve() == (sdk / ('cmdline-tools/' + pins['ANDROID_TOOLS_VERSION'])).resolve(), "Android stable link drift")
        prop(sdk / "cmdline-tools/latest/source.properties", 'Pkg.Revision', pins['ANDROID_TOOLS_VERSION'])
        prop(sdk / "platform-tools/source.properties", 'Pkg.Revision')
        prop(sdk / f"platforms/{pins['ANDROID_PLATFORM']}/source.properties", 'AndroidVersion.ApiLevel', pins['ANDROID_PLATFORM'].removeprefix('android-'))
        for directory, key in [('build-tools','ANDROID_BUILD_TOOLS'), ('ndk','ANDROID_NDK')]:
            prop(sdk / f"{directory}/{pins[key]}/source.properties", 'Pkg.Revision', pins[key])
        executable(sdk / f"ndk/{pins['ANDROID_NDK']}/toolchains/llvm/prebuilt/linux-x86_64/python3/bin/python3")
        require((sdk / 'licenses/android-sdk-license').stat().st_size > 0, "Android licenses missing")
    elif tool == "playwright_chromium":
        os_release = (root / 'etc/os-release').read_text()
        require(re.search(r'^ID=[\"\']?ubuntu[\"\']?$', os_release, re.M) and
                re.search(r'^VERSION_ID=[\"\']?26\.04[\"\']?$', os_release, re.M) and
                os.uname().machine == 'x86_64', "unsupported Playwright OS/architecture")
        gs = Path(git_home) / 'gstack'
        dep = json.loads((gs / 'package.json').read_text())['dependencies']['playwright']
        installed = json.loads((gs / 'node_modules/playwright/package.json').read_text())['version']
        require(dep in (pins['PLAYWRIGHT_VERSION'], '^' + pins['PLAYWRIGHT_VERSION']) and installed == pins['PLAYWRIGHT_VERSION'], "unsupported Playwright pin")
        rows = [('chromium-' + pins['PLAYWRIGHT_CHROMIUM_REVISION'], 'CHROMIUM', 'chrome-linux64/chrome'),
                ('chromium_headless_shell-' + pins['PLAYWRIGHT_CHROMIUM_REVISION'], 'HEADLESS', 'chrome-headless-shell-linux64/chrome-headless-shell'),
                ('ffmpeg-' + pins['PLAYWRIGHT_FFMPEG_REVISION'], 'FFMPEG', 'ffmpeg-linux')]
        for directory, key, binary in rows:
            target = home / '.cache/ms-playwright' / directory
            require((target / 'INSTALLATION_COMPLETE').is_file(), f"incomplete browser {directory}")
            text_is(target / '.setup-kit-sha256', pins['PLAYWRIGHT_' + key + '_SHA256'])
            executable(target / binary)
            content(target, binary)
    else:
        raise Drift("unknown tool")


if __name__ == '__main__':
    try:
        main()
    except Drift as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.SubprocessError):
        print('Missing or unreadable pinned tool state; rerun its component install.', file=sys.stderr)
        sys.exit(1)
