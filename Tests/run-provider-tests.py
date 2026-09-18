#!/usr/bin/env python3
"""Run fixtures by default; --live reads real usage through the installed, signed-in CLIs.
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
        text = source.read_text()
        text = text.replace('let executable = try codexExecutable()', f'let executable = URL(fileURLWithPath: "{mock}")')
        source = temp / 'Providers.swift'
        source.write_text(text)
    claude_source = root / 'Sources/ClaudeCLI.swift'
    if not live:
        mock_claude = temp / 'mock-claude'
        shutil.copy2(root / 'Tests/mock-claude', mock_claude)
        mock_claude.chmod(0o700)
        claude_text = claude_source.read_text().replace('let executable = try executableURL()', f'let executable = URL(fileURLWithPath: "{mock_claude}")')
        claude_source = temp / 'ClaudeCLI.swift'
        claude_source.write_text(claude_text)
    binary = temp / 'provider-tests'
    subprocess.run(['swiftc', '-module-cache-path', str(root / '.build/provider-test-cache'),
                    '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx13.0',
                    str(source), str(claude_source), str(test), '-o', str(binary)], check=True)
    subprocess.run([str(binary)] + (['codex', 'claude'] if live else []), cwd=temp, check=True, timeout=120)
