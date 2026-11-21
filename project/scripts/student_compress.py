#!/usr/bin/env python3
"""Package the submission globs, including files directly below each directory."""
import argparse
import json
from pathlib import Path
import re
import tarfile


def collect(root, patterns):
    files = set()
    for pattern in patterns:
        files.update(p for p in root.glob(pattern) if p.is_file())
    for path in files:
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Submission path escapes project: {path}")
    return sorted(files)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--id', required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.id):
        parser.error('UNITY_ID must contain only letters, digits, underscores or hyphens')
    files = collect(args.root, json.loads(args.config.read_text())['include_globs'])
    if not files:
        parser.error('No submission files match the configured globs')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    archive = args.output_dir / f'submission.{args.id}.tar.gz'
    with tarfile.open(archive, 'w:gz') as out:
        for path in files:
            out.add(path, arcname=path.relative_to(args.root), recursive=False)
            print(path)
    print(f'Submission: {archive} ({len(files)} files)')


if __name__ == '__main__':
    main()
