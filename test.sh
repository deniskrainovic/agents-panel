#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/tests .build/test-module-cache
if [[ "${1:-}" == "--ui" ]]; then
  swiftc -swift-version 5 -O -gnone -D PANEL_TESTING -module-cache-path "$PWD/.build/test-module-cache" Sources/*.swift Tests/SwitchResponsivenessTests.swift -o .build/tests/switch-responsiveness-tests
  .build/tests/switch-responsiveness-tests
  exit 0
fi
swiftc -swift-version 5 -O -module-cache-path "$PWD/.build/test-module-cache" Sources/TokenHistory.swift Tests/TokenHistoryTests.swift -o .build/tests/token-history-tests
.build/tests/token-history-tests
swiftc -swift-version 5 -O -gnone -D PANEL_TESTING -module-cache-path "$PWD/.build/test-module-cache" Sources/*.swift Tests/StoreRefreshTests.swift -o .build/tests/store-refresh-tests
.build/tests/store-refresh-tests
python3 Tests/run-provider-tests.py
