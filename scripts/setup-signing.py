#!/usr/bin/env python3
"""Keep this personal Mac app's signing identity stable without changing system trust."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path.home() / 'Library/Application Support/The One Ring Planner/Signing'
CONFIG = ROOT / 'identity.json'
NAME = 'The One Ring Planner Local Signing'

def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Signing setup failed')
    return result.stdout

def identity():
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if CONFIG.exists():
        config = json.loads(CONFIG.read_text())
        fingerprint = config['sha1']
        public = run(['/usr/bin/security', 'find-certificate', '-c', NAME, '-p'])
        with tempfile.TemporaryDirectory(prefix='one-ring-cert-') as tmp:
            pem = Path(tmp) / 'public.pem'; pem.write_text(public)
            der = subprocess.check_output(['/usr/bin/openssl', 'x509', '-in', str(pem), '-outform', 'DER'])
        if hashlib.sha1(der).hexdigest().upper() != fingerprint:
            raise RuntimeError('The saved planner signing certificate is missing or changed. Restore it rather than creating another identity.')
        return config
    existing = subprocess.run(['/usr/bin/security', 'find-certificate', '-c', NAME], capture_output=True)
    if existing.returncode == 0:
        raise RuntimeError('A planner signing certificate already exists. Restore its identity.json before rebuilding; do not rotate it automatically.')
    with tempfile.TemporaryDirectory(prefix='one-ring-signing-') as tmp:
        folder = Path(tmp)
        key, cert, config, p12 = [folder / name for name in ['private.pem', 'public.pem', 'openssl.cnf', 'identity.p12']]
        config.write_text('[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=extensions\n[subject]\nCN=' + NAME + '\n[extensions]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
        run(['/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:3072', '-nodes', '-x509', '-sha256', '-days', '3650', '-config', str(config), '-keyout', str(key), '-out', str(cert)])
        os.chmod(key, 0o600)
        secret = os.urandom(32).hex()
        password_file = folder / 'export-password'; password_file.write_text(secret); os.chmod(password_file, 0o600)
        run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(cert), '-name', NAME, '-out', str(p12), '-passout', 'file:' + str(password_file)])
        # Import only into this user's login keychain. The signing tool alone is trusted
        # for this new private key. No root certificate trust settings are changed.
        run(['/usr/bin/security', 'import', str(p12), '-k', str(Path.home() / 'Library/Keychains/login.keychain-db'), '-P', secret, '-T', '/usr/bin/codesign'])
        der = subprocess.check_output(['/usr/bin/openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
        result = {'sha1': hashlib.sha1(der).hexdigest().upper(), 'name': NAME}
        (ROOT / 'public.cer').write_bytes(der)
        CONFIG.write_text(json.dumps(result, indent=2) + '\n'); os.chmod(CONFIG, 0o600)
        return result

if __name__ == '__main__':
    try:
        print(identity()['sha1'])
    except Exception as error:
        raise SystemExit(str(error))
