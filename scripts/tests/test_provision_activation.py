"""Exercise the shipped provisioning helpers against the cookie-bound setup contract."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")
BASH = shutil.which("bash")
if os.name == "nt":
    git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
    BASH = str(git_bash) if git_bash.is_file() else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/api/platform/setup/v1/bootstrap":
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "vdx_setup_administrator_activation=fixture; Path=/api/platform/setup/v1; HttpOnly; SameSite=Strict")
        self.end_headers()
        self.wfile.write(json.dumps({"activation": {"manualActivationLink": None}}).encode())

    def do_GET(self):
        self.server.continuations += 1
        if self.path != "/api/platform/setup/v1/administrator-activation" or self.headers.get("Cookie") != "vdx_setup_administrator_activation=fixture":
            self.send_response(404)
        else:
            self.send_response(302)
            self.send_header("Location", "/activate#fixture-token")
        self.end_headers()


class ProvisionActivationTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.continuations = 0
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    @unittest.skipUnless(PWSH, "PowerShell is required")
    def test_powershell_preserves_cookie_and_keeps_manual_delivery(self):
        # Load the real functions through PowerShell's parser, without running provisioning.
        script = Path(self.temp.name) / "check.ps1"
        script.write_text("""
param([string]$Source, [string]$Url, [switch]$MissingCookie)
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile($Source, [ref]$null, [ref]$null)
$names = @('Fail', 'Invoke-Json', 'Get-LocationHeader', 'Invoke-OperatorRedirect', 'Resolve-SetupAdministratorActivationLink')
$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names}, $false) | ForEach-Object { Invoke-Expression $_.Extent.Text }
$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
if ($MissingCookie) {
    Resolve-SetupAdministratorActivationLink -Bootstrap ([pscustomobject]@{activation=$null}) -PlatformUrl $Url -WebSession $session
    throw 'Missing capability must fail'
}
$bootstrap = Invoke-Json -Method Post -Uri "$Url/api/platform/setup/v1/bootstrap" -Body @{} -WebSession $session
$link = Resolve-SetupAdministratorActivationLink -Bootstrap $bootstrap -PlatformUrl $Url -WebSession $session
if ($link -ne '/activate#fixture-token') { throw 'Cookie-bound continuation did not resolve' }
$manual = [pscustomobject]@{activation=[pscustomobject]@{manualActivationLink='/activate#manual-fixture'}}
if ((Resolve-SetupAdministratorActivationLink $manual $Url $session) -ne '/activate#manual-fixture') { throw 'Manual delivery changed' }
Write-Output 'PASS'
""", encoding="utf-8")
        result = subprocess.run([PWSH, "-NoProfile", "-File", str(script), str(SCRIPTS / "provision.ps1"), self.url], capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("PASS", result.stdout.strip())
        self.assertEqual(1, self.server.continuations)
        refused = subprocess.run([PWSH, "-NoProfile", "-File", str(script), str(SCRIPTS / "provision.ps1"), self.url, "-MissingCookie"], capture_output=True, text=True, timeout=30)
        self.assertNotEqual(0, refused.returncode)
        self.assertIn("stage=setup-continuation", refused.stdout)
        self.assertNotIn("fixture-token", refused.stdout + refused.stderr)
        self.assertEqual(2, self.server.continuations)

    @unittest.skipUnless(BASH, "Bash is required")
    def test_bash_preserves_cookie_and_refuses_missing_capability(self):
        source = (SCRIPTS / "provision.sh").read_text()
        functions = re.search(r"^fail\(\).*$", source, re.M).group(0) + "\n" + "\n".join(
            re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.M | re.S).group(0)
            for name in ("post_json", "resume_administrator_activation"))
        cookie = Path(self.temp.name) / "cookies"
        env = dict(os.environ, PLATFORM_URL=self.url, COOKIE_JAR=cookie.as_posix())
        script = Path(self.temp.name) / "check.sh"
        script.write_text("set -e\n" + functions + "\npost_json \"$PLATFORM_URL/api/platform/setup/v1/bootstrap\" '{}' '' \"$COOKIE_JAR\" >/dev/null\nlink=$(resume_administrator_activation)\n[ \"$link\" = '/activate#fixture-token' ]\n: > \"$COOKIE_JAR\"\nresume_administrator_activation\n", encoding="utf-8")
        result = subprocess.run([BASH, script.as_posix()], env=env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("stage=setup-continuation; HTTP 404", result.stderr)
        self.assertNotIn("fixture-token", result.stdout + result.stderr)
        self.assertEqual(2, self.server.continuations)


if __name__ == "__main__":
    unittest.main()
