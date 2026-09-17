#!/usr/bin/env python3
"""Run fixtures by default; --live reads real usage and may prompt for Keychain access.
Only a temporary source copy is instrumented for deterministic process/parser tests.
"""
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
live = '--live' in sys.argv
with tempfile.TemporaryDirectory(prefix='agent-panel-provider-tests-') as directory:
    temp = pathlib.Path(directory)
    source = root / 'Sources/Providers.swift'
    test = root / ('Tests/ProviderLiveTests.swift' if live else 'Tests/ProviderFixtureTests.swift')
    if not live:
        mock = temp / 'mock-codex'
        shutil.copy2(root / 'Tests/mock-codex', mock)
        mock.chmod(0o700)
        # Keep the shipped interface private. Only this temporary test copy exposes parsing.
        text = source.read_text().replace('private static func parseClaudeUsage', 'static func parseClaudeUsage')
        text = text.replace('let executable = try codexExecutable()', f'let executable = URL(fileURLWithPath: "{mock}")')
        source = temp / 'Providers.swift'
        source.write_text(text)
    binary = temp / 'provider-tests'
    subprocess.run(['swiftc', '-module-cache-path', str(root / '.build/provider-test-cache'),
                    '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx13.0',
                    str(source), str(test), '-o', str(binary)], check=True)
    subprocess.run([str(binary)] + (['codex', 'claude'] if live else []), cwd=temp, check=True, timeout=120)
