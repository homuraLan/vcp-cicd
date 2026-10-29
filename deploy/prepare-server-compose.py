#!/usr/bin/env python3
"""Resolve deployment paths without evaluating production config as shell code."""
import json
import os
from pathlib import Path
import posixpath
import re
import stat
import sys


def configured_paths(path):
    """Only read the two path keys; never render credentials or other settings."""
    result = {}
    pattern = re.compile(r'^\s*(?:export\s+)?(TDB_KNOWLEDGE_(?:ROOT|STORE)_PATH)\s*=\s*(.*)$')
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        match = pattern.match(line)
        if not match:
            continue
        key, value = match.groups()
        value = value.strip()
        if value.startswith(('"', "'")):
            quote = value[0]
            end = value.find(quote, 1)
            if end < 0 or value[end + 1:].split('#', 1)[0].strip():
                raise ValueError(f'{key} must contain a single-line path')
            value = value[1:end]
        else:
            value = value.split('#', 1)[0].strip()
        result[key] = value
    return result


def container_path(value):
    if any(c in value for c in '\r\n\x00'):
        raise ValueError('Container paths must be single-line paths')
    # TDBKnowledge calls path.resolve() from /usr/src/app for relative paths.
    value = posixpath.normpath(posixpath.join('/usr/src/app', value))
    if value in ('/', '/usr', '/usr/src', '/usr/src/app'):
        raise ValueError('Knowledge mounts must not hide the application directory')
    protected = ('node_modules', 'pydeps', 'rust-vexus-lite', 'Plugin', 'modules', 'routes',
                 'config.env', 'rag_params.json', 'TVStxt', 'ToolConfigs', 'dailynote', 'VectorStore')
    for name in protected:
        reserved = '/usr/src/app/' + name
        if posixpath.commonpath((value, reserved)) in (value, reserved):
            raise ValueError(f'Knowledge mount overlaps an existing application path: {reserved}')
    return value


def host_path(value, base):
    if any(c in str(value) for c in '\r\n\x00'):
        raise ValueError('Host paths must be single-line paths')
    path = Path(value)
    return (path if path.is_absolute() else base / path).resolve()


def ensure_directory(path, reference):
    if path.exists():
        if not path.is_dir():
            raise ValueError(f'Expected a directory: {path}')
        return
    metadata = reference.stat()
    missing = []
    cursor = path
    while not cursor.exists():
        missing.append(cursor)
        cursor = cursor.parent
    for directory in reversed(missing):
        directory.mkdir(mode=stat.S_IMODE(metadata.st_mode))
        if hasattr(os, 'chown'):
            os.chown(directory, metadata.st_uid, metadata.st_gid)
        directory.chmod(stat.S_IMODE(metadata.st_mode))


def prepare(template, destination, env):
    base = Path(env['DEPLOY_DIR']).resolve()
    config = base / 'config.env'
    if not config.is_file():
        raise ValueError(f'Missing production config file: {config}')
    existing = configured_paths(config)
    root_target = container_path(env.get('TDB_KNOWLEDGE_ROOT_PATH') or existing.get('TDB_KNOWLEDGE_ROOT_PATH') or '/usr/src/app/knowledge')
    store_target = container_path(env.get('TDB_KNOWLEDGE_STORE_PATH') or existing.get('TDB_KNOWLEDGE_STORE_PATH') or '/usr/src/app/VectorStoreTDB')
    if posixpath.commonpath((root_target, store_target)) in (root_target, store_target):
        raise ValueError('Knowledge source and database container paths must not overlap')
    root = host_path(env.get('KNOWLEDGE_SOURCE_DIR') or 'knowledge', base)
    store = host_path(env.get('TDB_STORE_DIR') or 'VectorStoreTDB', base)
    if root.is_relative_to(store) or store.is_relative_to(root):
        raise ValueError('Knowledge source and database host directories must not overlap')
    rag = host_path(env.get('RAG_PARAMS_FILE') or 'rag_params.json', base)
    if not rag.is_file():
        raise ValueError(f'Missing rag_params JSON file (will not create a directory): {rag}')
    with rag.open(encoding='utf-8-sig') as handle:
        if not isinstance(json.load(handle), dict):
            raise ValueError('rag_params.json must contain a JSON object')
    for directory in (root, store):
        if directory.exists() and not directory.is_dir():
            raise ValueError(f'Expected a directory: {directory}')
    reference = root if root.is_dir() else base / 'dailynote'
    if not reference.is_dir():
        reference = base
    ensure_directory(root, reference)
    ensure_directory(store, root)
    values = {
        '__IMAGE__': env['TARGET_IMAGE'],
        '__KNOWLEDGE_SOURCE__': str(root), '__KNOWLEDGE_TARGET__': root_target,
        '__TDB_STORE_SOURCE__': str(store), '__TDB_STORE_TARGET__': store_target,
        '__RAG_PARAMS_SOURCE__': str(rag),
    }
    rendered = Path(template).read_text(encoding='utf-8')
    for key, value in values.items():
        # JSON strings are YAML scalars. Escape Compose interpolation in literal paths.
        rendered = rendered.replace(key, json.dumps(value.replace('$', '$$'), ensure_ascii=False))
    Path(destination).write_text(rendered, encoding='utf-8', newline='\n')


if __name__ == '__main__':
    try:
        prepare(sys.argv[1], sys.argv[2], os.environ)
    except (OSError, ValueError) as exc:
        print(f'Deployment preflight failed: {exc}', file=sys.stderr)
        sys.exit(1)
