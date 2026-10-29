#!/usr/bin/env python3
"""Launch two real app bundles to verify stable identity against a synthetic Keychain item."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid
spec = importlib.util.spec_from_file_location('planner_signing', Path(__file__).with_name('setup-signing.py'))
setup = importlib.util.module_from_spec(spec); spec.loader.exec_module(setup)
identity = setup.identity()['sha1']
identifier = 'com.t1a.the-one-ring-planner.signing-check'
requirement = '=designated => identifier "' + identifier + '" and certificate leaf = H"' + identity + '"'
source = r'''
import AppKit
import Security
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async {
 let mode = CommandLine.arguments[1], service = CommandLine.arguments[2], output = CommandLine.arguments[3]
 let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "synthetic"]
 var status: OSStatus = 0
 if mode == "write" {
  var value = query; value[kSecValueData as String] = Data("synthetic-signing-fixture".utf8)
  var trusted: SecTrustedApplication?; var access: SecAccess?
  status = SecTrustedApplicationCreateFromPath(nil, &trusted)
  if status == errSecSuccess { status = SecAccessCreate("Synthetic planner signature test" as CFString, [trusted!] as CFArray, &access) }
  if status == errSecSuccess { value[kSecAttrAccess as String] = access!; status = SecItemAdd(value as CFDictionary, nil) }
 } else if mode == "read" {
  var value = query; value[kSecReturnData as String] = true; value[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  var result: CFTypeRef?
  status = SecItemCopyMatching(value as CFDictionary, &result)
  if status == errSecSuccess && (result as? Data) != Data("synthetic-signing-fixture".utf8) { status = -1 }
 } else { status = SecItemDelete(query as CFDictionary) }
 try? String(status).write(toFile: output, atomically: true, encoding: .utf8)
 app.terminate(nil)
}
app.run()
'''
def run(args):
    subprocess.run(args, check=True, capture_output=True)
with tempfile.TemporaryDirectory(prefix='one-ring-signing-test-') as folder:
    root = Path(folder); swift = root / 'probe.swift'
    bundles = []
    for version in [1, 2]:
        bundle = root / f'Version{version}.app'; binary = bundle / 'Contents/MacOS/Probe'
        binary.parent.mkdir(parents=True)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier, 'CFBundleExecutable':'Probe', 'CFBundleName':'Planner Signing Test', 'CFBundlePackageType':'APPL', 'CFBundleVersion':str(version), 'LSUIElement':True}))
        swift.write_text(source + f'\n// version {version}\n')
        run(['/usr/bin/swiftc', str(swift), '-o', str(binary)])
        run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', '--requirements', requirement, str(bundle)])
        run(['/usr/bin/codesign', '--verify', '--strict', str(bundle)])
        bundles.append(bundle)
    other = root / 'Other.app'; shutil.copytree(bundles[1], other)
    run(['/usr/bin/codesign', '--remove-signature', str(other)])
    run(['/usr/bin/codesign', '--force', '--sign', '-', str(other)])
    # Check actual signatures before testing access; matching names are not sufficient.
    for bundle in bundles:
        run(['/usr/bin/codesign', '--verify', '-R', '=' + requirement.split('=> ', 1)[1], str(bundle)])
    if subprocess.run(['/usr/bin/codesign', '--verify', '-R', '=' + requirement.split('=> ', 1)[1], str(other)], capture_output=True).returncode == 0:
        raise RuntimeError('The negative test still has the trusted signature')
    requirements = [subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(b)], capture_output=True, text=True).stdout for b in bundles]
    if requirements[0] != requirements[1]: raise RuntimeError('The designated requirement changed between app versions')
    print('PASS Both signed app versions retain the exact same designated requirement')
    service = 'com.t1a.synthetic-signing-' + str(uuid.uuid4())
    def launch(bundle, mode):
        output = root / (mode + '-' + bundle.stem + '.txt')
        subprocess.run(['/usr/bin/open', '-n', '-W', str(bundle), '--args', mode, service, str(output)], check=True, capture_output=True)
        return int(output.read_text())
    if launch(bundles[0], 'write') != 0: raise RuntimeError('Could not create the synthetic key')
    try:
        if launch(bundles[1], 'read') != 0: raise RuntimeError('The rebuilt app could not reuse its authorization')
        print('PASS Changed app builds with the stable certificate reuse Keychain access without UI')
        print('PASS A different signer with the same identifier fails the pinned certificate requirement')
    finally:
        if launch(bundles[0], 'delete') != 0: raise RuntimeError('Could not remove the synthetic test key')
