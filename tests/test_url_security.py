#!/usr/bin/env python3
"""
Automated security tests for omarchy-paperless-plugin.
Verifies URL security validation in Panel.qml against host confusion,
credential leakage, and improper protocol attacks.
"""

import json
import os
import re
import subprocess
import tempfile
import unittest

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANEL_QML_PATH = os.path.join(PLUGIN_DIR, "Panel.qml")
MANIFEST_PATH = os.path.join(PLUGIN_DIR, "manifest.json")


def extract_is_url_secure_function():
    with open(PANEL_QML_PATH, "r", encoding="utf-8") as f:
        content = f.read()
    match = re.search(r"function isUrlSecure\(url\)\s*\{[\s\S]*?\n  \}", content)
    if not match:
        raise ValueError("Could not find isUrlSecure in Panel.qml")
    return match.group(0)


def run_is_url_secure_batch(urls):
    func_code = extract_is_url_secure_function()
    urls_json = json.dumps(urls)

    qml_script = f"""import QtQuick
Item {{
  {func_code}

  Component.onCompleted: {{
    var testUrls = {urls_json};
    var results = {{}};
    for (var i = 0; i < testUrls.length; i++) {{
      var u = testUrls[i];
      try {{
        results[u] = isUrlSecure(u);
      }} catch (e) {{
        results[u] = false;
      }}
    }}
    console.log("TEST_RESULTS_JSON:" + JSON.stringify(results));
    Qt.quit();
  }}
}}
"""
    with tempfile.NamedTemporaryFile("w", suffix=".qml", delete=False) as tf:
        tf.write(qml_script)
        tf_name = tf.name

    try:
        proc = subprocess.run(
            ["qml6", tf_name],
            capture_output=True,
            text=True,
            check=True
        )
        for line in proc.stdout.splitlines() + proc.stderr.splitlines():
            if "TEST_RESULTS_JSON:" in line:
                json_part = line.split("TEST_RESULTS_JSON:", 1)[1]
                return json.loads(json_part)
        raise RuntimeError("No results found in qml output: " + proc.stderr)
    finally:
        if os.path.exists(tf_name):
            os.remove(tf_name)


class TestUrlSecurity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.valid_urls = [
            "http://localhost:8000",
            "http://localhost:8000/",
            "http://localhost:8000/paperless",
            "http://localhost",
            "http://localhost/",
            "http://127.0.0.1:8000",
            "http://127.0.0.1:8000/",
            "http://127.0.0.1",
            "http://[::1]:8000",
            "http://[::1]:8000/",
            "http://[::1]",
            "https://paperless.example.com",
            "https://paperless.example.com/",
            "https://paperless.example.com:8443",
            "https://paperless.example.com:8443/paperless",
            "https://localhost:8000",
            "https://127.0.0.1:8000",
            "https://my-paperless.internal.net",
            "https://sub.domain.tld:9000/sub/path",
        ]

        cls.malicious_or_invalid_urls = [
            # The reported vulnerability vector
            "http://localhost:80@attacker.example",
            # Additional host confusion / userinfo attacks
            "http://localhost@attacker.example",
            "http://127.0.0.1:80@attacker.example",
            "http://[::1]:80@attacker.example",
            "http://user:pass@localhost:8000",
            "http://user@localhost:8000",
            "http://attacker.example:80@localhost:8000",
            "https://user:pass@attacker.example",
            "https://localhost:80@attacker.example",
            # Non-local plain HTTP
            "http://attacker.example",
            "http://example.com",
            "http://192.168.1.100",
            "http://10.0.0.1",
            "http://localhost.attacker.example",
            "http://127.0.0.1.attacker.example",
            "http://localhost:8000.attacker.example",
            # Query and fragment injection
            "http://localhost#@attacker.example",
            "http://localhost?@attacker.example",
            "http://attacker.example#localhost",
            "http://attacker.example?localhost",
            # Port manipulation
            "http://localhost:99999",
            "http://localhost:-1",
            "http://localhost:0",
            "http://localhost:abc",
            # Backslash tricks
            "http://localhost\\attacker.example",
            # Schemes
            "ftp://localhost:8000",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,...",
            "//localhost:8000",
            "localhost:8000",
            "",
            # Whitespace and control chars
            "http://localhost:8000\nattacker.example",
            'http://localhost:8000"attacker.example',
            "http://localhost:8000'attacker.example",
            "http://localhost:8000 attacker.example",
        ]

        all_urls = cls.valid_urls + cls.malicious_or_invalid_urls
        cls.results = run_is_url_secure_batch(all_urls)

    def test_exploit_vector_rejected(self):
        exploit = "http://localhost:80@attacker.example"
        self.assertFalse(
            self.results.get(exploit),
            f"Vulnerability check failed: {exploit} must be rejected!"
        )

    def test_all_malicious_and_invalid_urls_rejected(self):
        for u in self.malicious_or_invalid_urls:
            with self.subTest(url=u):
                self.assertFalse(
                    self.results.get(u),
                    f"Insecure URL was erroneously accepted: {u}"
                )

    def test_all_valid_urls_accepted(self):
        for u in self.valid_urls:
            with self.subTest(url=u):
                self.assertTrue(
                    self.results.get(u),
                    f"Valid URL was erroneously rejected: {u}"
                )

    def test_manifest_version(self):
        with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
            manifest = json.load(f)
        # 1.4.4 is the security release this test was written for; any
        # later version (this branch carries the 1.5.0 feature set) is
        # equally acceptable — what must never regress is a version
        # below the fixed one.
        self.assertGreaterEqual(manifest["version"], "1.4.4")
        self.assertEqual(manifest["id"], "paperless")


if __name__ == "__main__":
    unittest.main()
