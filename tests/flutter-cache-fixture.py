#!/usr/bin/env python3
# Minimal vendor archive payloads, independent of the installer implementation.
import io,json,os,pathlib,sys,tarfile,zipfile
root=pathlib.Path(sys.argv[1])
rows={'ANDROID_ARM_PROFILE_SNAPSHOT': {'path': 'flutter_infra_release/flutter/{engine}/android-arm-profile/linux-x64.zip', 'dest': 'artifacts/engine/android-arm-profile/linux-x64', 'kind': 'zip'}, 'ANDROID_ARM_RELEASE_SNAPSHOT': {'path': 'flutter_infra_release/flutter/{engine}/android-arm-release/linux-x64.zip', 'dest': 'artifacts/engine/android-arm-release/linux-x64', 'kind': 'zip'}, 'ANDROID_ARM64_PROFILE_SNAPSHOT': {'path': 'flutter_infra_release/flutter/{engine}/android-arm64-profile/linux-x64.zip', 'dest': 'artifacts/engine/android-arm64-profile/linux-x64', 'kind': 'zip'}, 'ANDROID_ARM64_RELEASE_SNAPSHOT': {'path': 'flutter_infra_release/flutter/{engine}/android-arm64-release/linux-x64.zip', 'dest': 'artifacts/engine/android-arm64-release/linux-x64', 'kind': 'zip'}, 'ANDROID_X64_PROFILE_SNAPSHOT': {'path': 'flutter_infra_release/flutter/{engine}/android-x64-profile/linux-x64.zip', 'dest': 'artifacts/engine/android-x64-profile/linux-x64', 'kind': 'zip'}, 'ANDROID_X64_RELEASE_SNAPSHOT': {'path': 'flutter_infra_release/flutter/{engine}/android-x64-release/linux-x64.zip', 'dest': 'artifacts/engine/android-x64-release/linux-x64', 'kind': 'zip'}, 'ANDROID_X86': {'path': 'flutter_infra_release/flutter/{engine}/android-x86/artifacts.zip', 'dest': 'artifacts/engine/android-x86', 'kind': 'zip'}, 'ANDROID_X64': {'path': 'flutter_infra_release/flutter/{engine}/android-x64/artifacts.zip', 'dest': 'artifacts/engine/android-x64', 'kind': 'zip'}, 'ANDROID_ARM': {'path': 'flutter_infra_release/flutter/{engine}/android-arm/artifacts.zip', 'dest': 'artifacts/engine/android-arm', 'kind': 'zip'}, 'ANDROID_ARM_PROFILE': {'path': 'flutter_infra_release/flutter/{engine}/android-arm-profile/artifacts.zip', 'dest': 'artifacts/engine/android-arm-profile', 'kind': 'zip'}, 'ANDROID_ARM_RELEASE': {'path': 'flutter_infra_release/flutter/{engine}/android-arm-release/artifacts.zip', 'dest': 'artifacts/engine/android-arm-release', 'kind': 'zip'}, 'ANDROID_ARM64': {'path': 'flutter_infra_release/flutter/{engine}/android-arm64/artifacts.zip', 'dest': 'artifacts/engine/android-arm64', 'kind': 'zip'}, 'ANDROID_ARM64_PROFILE': {'path': 'flutter_infra_release/flutter/{engine}/android-arm64-profile/artifacts.zip', 'dest': 'artifacts/engine/android-arm64-profile', 'kind': 'zip'}, 'ANDROID_ARM64_RELEASE': {'path': 'flutter_infra_release/flutter/{engine}/android-arm64-release/artifacts.zip', 'dest': 'artifacts/engine/android-arm64-release', 'kind': 'zip'}, 'ANDROID_X64_PROFILE': {'path': 'flutter_infra_release/flutter/{engine}/android-x64-profile/artifacts.zip', 'dest': 'artifacts/engine/android-x64-profile', 'kind': 'zip'}, 'ANDROID_X64_RELEASE': {'path': 'flutter_infra_release/flutter/{engine}/android-x64-release/artifacts.zip', 'dest': 'artifacts/engine/android-x64-release', 'kind': 'zip'}, 'HOST': {'path': 'flutter_infra_release/flutter/{engine}/linux-x64/artifacts.zip', 'dest': 'artifacts/engine/linux-x64', 'kind': 'zip'}, 'PATCHED': {'path': 'flutter_infra_release/flutter/{engine}/flutter_patched_sdk.zip', 'dest': 'artifacts/engine/common', 'kind': 'zip'}, 'PATCHED_PRODUCT': {'path': 'flutter_infra_release/flutter/{engine}/flutter_patched_sdk_product.zip', 'dest': 'artifacts/engine/common', 'kind': 'zip'}, 'SKY_ENGINE': {'path': 'flutter_infra_release/flutter/{engine}/sky_engine.zip', 'dest': 'pkg', 'kind': 'zip'}, 'FLUTTER_GPU': {'path': 'flutter_infra_release/flutter/{engine}/flutter_gpu.zip', 'dest': 'pkg', 'kind': 'zip'}, 'FONT_SUBSET': {'path': 'flutter_infra_release/flutter/{engine}/linux-x64/font-subset.zip', 'dest': 'artifacts/engine/linux-x64', 'kind': 'zip'}, 'FONTS': {'path': 'flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip', 'dest': 'artifacts/material_fonts', 'kind': 'zip'}, 'GRADLE': {'path': 'flutter_infra_release/gradle-wrapper/fd5c1f2c013565a3bea56ada6df9d2b8e96d56aa/gradle-wrapper.tgz', 'dest': 'artifacts/gradle_wrapper', 'kind': 'tgz'}, 'ENGINE_INFO': {'path': 'flutter_infra_release/flutter/{engine}/engine_stamp.json', 'dest': '.', 'kind': 'file'}}
urls={}
for key,row in rows.items():
    if key.endswith('_SNAPSHOT'): entries={'gen_snapshot':0o755}
    elif key.startswith('ANDROID_'): entries={'flutter.jar':0o644}
    else: entries={
      'HOST':{'gen_snapshot':0o755,'flutter_tester':0o755,'impellerc':0o755,'icudtl.dat':0o644},
      'FONT_SUBSET':{'font-subset':0o755,'const_finder.dart.snapshot':0o644},
      'PATCHED':{'flutter_patched_sdk/platform_strong.dill':0o644},
      'PATCHED_PRODUCT':{'flutter_patched_sdk_product/platform_strong.dill':0o644},
      'SKY_ENGINE':{'sky_engine/pubspec.yaml':0o644},
      'FLUTTER_GPU':{'flutter_gpu/pubspec.yaml':0o644},
      'FONTS':{'MaterialIcons-Regular.otf':0o644},
      'GRADLE':{'gradlew':0o755,'gradlew.bat':0o644,'gradle/wrapper/gradle-wrapper.jar':0o644},
      'ENGINE_INFO':{'engine_stamp.json':0o644}}[key]
    name=key+'.'+row['kind']; urls[row['path'].replace('{engine}',os.environ['FLUTTER_ENGINE_REVISION'])]=name
    if row['kind']=='zip':
        with zipfile.ZipFile(root/name,'w') as z:
            for entry,mode in entries.items():
                i=zipfile.ZipInfo(entry); i.external_attr=(0o100000|mode)<<16; z.writestr(i,'fixture payload\n')
    elif row['kind']=='tgz':
        with tarfile.open(root/name,'w:gz') as t:
            for entry,mode in entries.items():
                data=b'fixture payload\n'; i=tarfile.TarInfo(entry); i.mode=mode; i.size=len(data); t.addfile(i,io.BytesIO(data))
    else: (root/name).write_text('{"fixture":"engine information"}\n')
(root/'cache-fixtures.json').write_text(json.dumps(urls))
