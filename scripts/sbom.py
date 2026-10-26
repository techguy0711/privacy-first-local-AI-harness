"""CycloneDX 1.6 SBOM of what setup.sh installed here: Open WebUI's Python
packages, the Brave MCP server's npm packages, acp-bridge (its pinned commit,
our patches, its crates), the Ollama models and the Whisper model.

Run by setup.sh with Open WebUI's venv Python (so it sees those packages);
standard library only. Deterministic -- no timestamp or random serial -- so a
second setup run writes nothing. Usage: sbom.py OUTPUT_PATH
"""
import base64
import importlib.metadata as md
import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Ollama models whose GGUF metadata names no organization.
SUPPLIERS = {'gemma4': 'Google', 'llama': 'Meta', 'nomic-bert': 'Nomic AI', 'starcoder2': 'BigCode'}


def license_of(text):
    text = (text or '').strip()
    if not text:
        return []
    first = text.splitlines()[0].strip()
    if first.startswith('Apache License') and 'Version 2.0' in text[:200] or first.lower() in ('apache-2.0', 'apache 2.0'):
        return [{'license': {'id': 'Apache-2.0'}}]
    if first in ('MIT', 'MIT License', 'BSD-3-Clause', 'BSD-2-Clause', 'ISC', 'MPL-2.0', 'PSF-2.0'):
        return [{'license': {'id': first.removesuffix(' License')}}]
    return [{'license': {'name': first[:120]}}]


def python_packages():
    out = []
    for dist in md.distributions():
        name, version = dist.metadata['Name'], dist.version
        norm = re.sub(r'[-_.]+', '-', name).lower()
        meta_license = dist.metadata.get('License-Expression') or dist.metadata.get('License') or ''
        if '\n' in meta_license or len(meta_license) > 80:
            # The whole license text: keep its title ("Open WebUI License"), not a copyright line.
            first = (meta_license.strip().splitlines() or [''])[0].strip()
            meta_license = first if 'license' in first.lower() and len(first) <= 80 else ''
        purl = f'pkg:pypi/{norm}@{version}'
        out.append({'type': 'library', 'bom-ref': purl, 'name': norm, 'version': version, 'purl': purl,
                    'licenses': license_of(meta_license)})
    return out


def npm_packages(lock):
    out = []
    for path, entry in json.loads(lock.read_text())['packages'].items():
        if not path:
            continue
        name = path.rsplit('node_modules/', 1)[1]
        purl = f"pkg:npm/{name.replace('@', '%40', 1)}@{entry['version']}"
        component = {'type': 'library', 'bom-ref': purl, 'name': name, 'version': entry['version'], 'purl': purl,
                     'licenses': license_of(entry.get('license'))}
        alg, _, digest = entry.get('integrity', '').partition('-')
        if alg == 'sha512':
            component['hashes'] = [{'alg': 'SHA-512', 'content': base64.b64decode(digest).hex()}]
        out.append(component)
    return out


def acp_bridge():
    stamp = ROOT / 'bin/acp-bridge.stamp'
    if not stamp.exists():
        return []
    fields = dict(f.split('=', 1) for f in stamp.read_text().split())
    purl = f"pkg:github/BlakeHung/acp-bridge@{fields['commit']}"
    crates = []
    lock = ROOT / 'build/acp-bridge/src/Cargo.lock'
    if lock.exists():
        for p in tomllib.loads(lock.read_text()).get('package', []):
            if p['name'] == 'acp-bridge':
                continue
            cpurl = f"pkg:cargo/{p['name']}@{p['version']}"
            crate = {'type': 'library', 'bom-ref': cpurl, 'name': p['name'], 'version': p['version'], 'purl': cpurl}
            if p.get('checksum'):
                crate['hashes'] = [{'alg': 'SHA-256', 'content': p['checksum']}]
            crates.append(crate)
    return [{'type': 'application', 'bom-ref': purl, 'name': 'acp-bridge', 'version': fields['version'],
             'purl': purl, 'licenses': [{'license': {'id': 'MIT'}}],
             'hashes': [{'alg': 'SHA-256', 'content': fields['bin_sha256']}],
             'pedigree': {'patches': [{'type': 'unofficial', 'diff': {'url': f'editors/acp/{p}'}}
                                      for p in ('acp-bridge.patch', 'queue.patch')]},
             'components': crates}]


def ollama(base):
    def call(path, body=None):
        req = urllib.request.Request(base + path, json.dumps(body).encode() if body else None)
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)
    version = call('/api/version')['version']
    out = [{'type': 'application', 'bom-ref': f'pkg:github/ollama/ollama@v{version}', 'name': 'ollama',
            'version': version, 'purl': f'pkg:github/ollama/ollama@v{version}', 'licenses': [{'license': {'id': 'MIT'}}]}]
    for m in sorted(call('/api/tags')['models'], key=lambda m: m['name']):
        show = call('/api/show', {'model': m['name']})
        info, details = show.get('model_info', {}), m.get('details', {})
        family = info.get('general.architecture') or details.get('family', '')
        name, _, tag = m['name'].partition(':')
        model = {'type': 'machine-learning-model', 'bom-ref': 'ollama:' + m['name'], 'name': name, 'version': tag,
                 'supplier': {'name': info.get('general.base_model.0.organization') or SUPPLIERS.get(family, 'unknown')},
                 'licenses': license_of(show.get('license')),
                 'hashes': [{'alg': 'SHA-256', 'content': m['digest']}],
                 'properties': [{'name': 'ollama:' + k, 'value': str(details[k])}
                                for k in ('family', 'parameter_size', 'quantization_level', 'format') if details.get(k)]}
        if name.startswith('coder-'):
            model['supplier'] = {'name': 'this project (Modelfile.' + name.removeprefix('coder-') + ')'}
            model['pedigree'] = {'ancestors': [{'type': 'machine-learning-model', 'name': details.get('parent_model', '')}]}
        out.append(model)
    return out


def whisper():
    pins = os.environ.get('WHISPER_SHA256', '')
    if not pins:
        return []
    files = [line.split() for line in pins.splitlines() if line.strip()]
    return [{'type': 'machine-learning-model', 'bom-ref': 'hf:' + os.environ['WHISPER_REPO'],
             'name': os.environ['WHISPER_REPO'], 'version': os.environ['WHISPER_REVISION'],
             'supplier': {'name': 'SYSTRAN (CTranslate2 build of OpenAI Whisper small)'},
             'licenses': [{'license': {'id': 'MIT'}}],
             'components': [{'type': 'file', 'bom-ref': 'hf:' + os.environ['WHISPER_REPO'] + '/' + f, 'name': f,
                             'hashes': [{'alg': 'SHA-256', 'content': h}]} for h, f in files]}]


def main(out):
    try:
        revision = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], capture_output=True,
                                  text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        revision = 'unknown'
    components = python_packages()
    lock = ROOT / 'build/brave-mcp/package-lock.json'
    if lock.exists():
        components += npm_packages(lock)
    components += acp_bridge() + ollama(os.environ.get('OLLAMA_BASE_URL', 'http://127.0.0.1:11434')) + whisper()
    components.sort(key=lambda c: (c['type'], c['name'].lower(), c.get('version', '')))
    for c in components:
        if not c.get('licenses'):
            c.pop('licenses', None)
    bom = {'bomFormat': 'CycloneDX', 'specVersion': '1.6', 'version': 1,
           'metadata': {'component': {'type': 'application', 'bom-ref': 'harness',
                                      'name': 'privacy-first-local-AI-harness', 'version': revision,
                                      'licenses': [{'license': {'id': 'Apache-2.0'}}]},
                        'tools': {'components': [{'type': 'application', 'name': 'scripts/sbom.py'}]}},
           'components': components}
    text = json.dumps(bom, indent=2, sort_keys=True) + '\n'
    path = Path(out)
    if not path.exists() or path.read_text() != text:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f'wrote {path} ({len(components)} components)')
    else:
        print(f'{path} unchanged ({len(components)} components)')


if __name__ == '__main__':
    main(sys.argv[1])
