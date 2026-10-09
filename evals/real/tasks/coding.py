"""Coding task family for the real memory-on/off evaluation.

Every task is synthetic.  Success depends on project knowledge that exists
only in prior-session memory (never in the repository or the prompt), except
for the control tasks, where memory must not matter or is deliberately stale.
Hidden tests are copied in only at grading time.
"""

from textwrap import dedent


def d(text: str) -> str:
    return dedent(text).lstrip("\n")


# Unrelated notes seeded into every coding brain so retrieval is not trivial.
DISTRACTORS = [
    {"id": "note-ci-python", "title": "CI Python version", "text": "CI runs the unit tests on Python 3.11 and 3.12; keep code compatible with both."},
    {"id": "note-changelog", "title": "Where release notes live", "text": "Release notes are written in docs/CHANGES.md at release time, not in pull requests."},
    {"id": "note-small-prs", "title": "Pull request size", "text": "Team preference: keep pull requests under roughly 300 changed lines and split refactors from behaviour changes."},
    {"id": "note-oncall", "title": "On-call rotation", "text": "The on-call rotation changes every Monday; incidents are written up within two working days."},
]

TASKS = [
    {
        "id": "c01-receipt-price-format",
        "kind": "memory",
        "knowledge": "convention",
        "project_id": "proj_shop",
        "prompt": "Add a function `format_price(cents: int) -> str` to shop/money.py that formats an amount for display on customer receipts, following this project's conventions.",
        "files": {
            "README.md": "# Shop\n\nSmall cart service. Amounts are integer cents.\n",
            "shop/__init__.py": "",
            "shop/money.py": d('''
                """Money helpers. Amounts are integer cents."""


                def add(a_cents: int, b_cents: int) -> int:
                    return a_cents + b_cents
            '''),
            "shop/cart.py": d('''
                from shop.money import add


                def cart_total(lines):
                    total = 0
                    for line in lines:
                        total = add(total, line["qty"] * line["unit_cents"])
                    return total
            '''),
        },
        "memory": [
            {"id": "conv-receipt-format", "title": "Receipt price display convention", "text": "Receipt display convention: prices are shown as a plain decimal with exactly two places, a space, then the ISO currency code AUD, e.g. 1250 cents -> '12.50 AUD'. Never use a currency symbol. Negative amounts use a leading minus: -305 -> '-3.05 AUD'."},
        ],
        "memory_only": ["AUD"],
        "hidden_test": d('''
            import unittest
            from shop.money import format_price


            class T(unittest.TestCase):
                def test_format(self):
                    self.assertEqual(format_price(1250), "12.50 AUD")
                    self.assertEqual(format_price(5), "0.05 AUD")
                    self.assertEqual(format_price(0), "0.00 AUD")
                    self.assertEqual(format_price(-305), "-3.05 AUD")


            unittest.main()
        '''),
        "reference": {
            "queries": ["receipt price display format"],
            "needs": ["AUD"],
            "solution": {"shop/money.py": d('''
                """Money helpers. Amounts are integer cents."""


                def add(a_cents: int, b_cents: int) -> int:
                    return a_cents + b_cents


                def format_price(cents: int) -> str:
                    sign = "-" if cents < 0 else ""
                    cents = abs(cents)
                    return f"{sign}{cents // 100}.{cents % 100:02d} AUD"
            ''')},
            "naive": {"shop/money.py": d('''
                """Money helpers. Amounts are integer cents."""


                def add(a_cents: int, b_cents: int) -> int:
                    return a_cents + b_cents


                def format_price(cents: int) -> str:
                    return f"${cents / 100:.2f}"
            ''')},
        },
    },
    {
        "id": "c02-retry-policy",
        "kind": "memory",
        "knowledge": "past-decision",
        "project_id": "proj_reports",
        "prompt": "fetch_report in client/reports.py fails on transient errors. Add retry behaviour that follows the team's agreed retry policy. Retries may be immediate (do not sleep); tests call it directly.",
        "files": {
            "README.md": "# Reports client\n\nThin client for the reporting service.\n",
            "client/__init__.py": "",
            "client/http.py": d('''
                class HTTPError(Exception):
                    def __init__(self, status):
                        super().__init__(f"HTTP {status}")
                        self.status = status
            '''),
            "client/reports.py": d('''
                from client.http import HTTPError


                def fetch_report(transport, report_id):
                    """Fetch a report. `transport(path)` returns a dict or raises HTTPError."""
                    return transport(f"/reports/{report_id}")
            '''),
        },
        "memory": [
            {"id": "decision-retry-policy", "title": "Retry policy for service clients", "text": "Retry policy decided after incident INC-212: at most 4 attempts in total, retry only on HTTP 5xx and 429, never retry any other 4xx, and re-raise the last HTTPError when attempts are exhausted."},
        ],
        "memory_only": ["INC-212", "429", "4 attempts"],
        "hidden_test": d('''
            import unittest
            from client.http import HTTPError
            from client.reports import fetch_report


            def scripted(*outcomes):
                calls = []

                def transport(path):
                    calls.append(path)
                    outcome = outcomes[min(len(calls), len(outcomes)) - 1]
                    if isinstance(outcome, int):
                        raise HTTPError(outcome)
                    return outcome
                return transport, calls


            class T(unittest.TestCase):
                def test_gives_up_after_four(self):
                    transport, calls = scripted(503)
                    with self.assertRaises(HTTPError):
                        fetch_report(transport, "r1")
                    self.assertEqual(len(calls), 4)

                def test_no_retry_on_404(self):
                    transport, calls = scripted(404)
                    with self.assertRaises(HTTPError):
                        fetch_report(transport, "r1")
                    self.assertEqual(len(calls), 1)

                def test_retries_429(self):
                    transport, calls = scripted(429, 429, {"ok": True})
                    self.assertEqual(fetch_report(transport, "r1"), {"ok": True})
                    self.assertEqual(len(calls), 3)

                def test_succeeds_on_fourth(self):
                    transport, calls = scripted(500, 502, 503, {"ok": 1})
                    self.assertEqual(fetch_report(transport, "r1"), {"ok": 1})


            unittest.main()
        '''),
        "reference": {
            "queries": ["retry policy transient errors"],
            "needs": ["429", "4 attempts"],
            "solution": {"client/reports.py": d('''
                from client.http import HTTPError

                MAX_ATTEMPTS = 4


                def _retryable(error):
                    return error.status == 429 or 500 <= error.status < 600


                def fetch_report(transport, report_id):
                    """Fetch a report. `transport(path)` returns a dict or raises HTTPError."""
                    for attempt in range(1, MAX_ATTEMPTS + 1):
                        try:
                            return transport(f"/reports/{report_id}")
                        except HTTPError as error:
                            if not _retryable(error) or attempt == MAX_ATTEMPTS:
                                raise
            ''')},
            "naive": {"client/reports.py": d('''
                from client.http import HTTPError


                def fetch_report(transport, report_id, retries=3):
                    """Fetch a report. `transport(path)` returns a dict or raises HTTPError."""
                    for attempt in range(retries):
                        try:
                            return transport(f"/reports/{report_id}")
                        except HTTPError:
                            if attempt == retries - 1:
                                raise
            ''')},
        },
    },
    {
        "id": "c03-legacy-timestamps",
        "kind": "memory",
        "knowledge": "gotcha",
        "project_id": "proj_events",
        "prompt": "Add `events_since(rows, since)` to events/store.py: return the rows whose timestamp is at or after the timezone-aware datetime `since`, sorted oldest first.",
        "files": {
            "README.md": "# Events\n\nHelpers over event rows from the legacy collector.\n",
            "events/__init__.py": "",
            "events/store.py": d('''
                """Event rows come from the legacy collector as dicts: {"id": str, "ts": int, "kind": str}."""


                def by_kind(rows, kind):
                    return [row for row in rows if row["kind"] == kind]
            '''),
        },
        "memory": [
            {"id": "gotcha-collector-ts", "title": "Legacy collector ts unit", "text": "Gotcha: the legacy collector's ts field is Unix epoch MILLISECONDS in UTC, not seconds, despite the name; divide by 1000 before converting to a datetime."},
        ],
        "memory_only": ["MILLISECONDS", "illisecond", "1000"],
        "hidden_test": d('''
            import unittest
            from datetime import datetime, timezone
            from events.store import events_since

            ROWS = [
                {"id": "c", "ts": 1767312000000, "kind": "x"},
                {"id": "a", "ts": 1767139200000, "kind": "x"},
                {"id": "b", "ts": 1767225600000, "kind": "y"},
            ]


            class T(unittest.TestCase):
                def test_since(self):
                    since = datetime(2026, 1, 1, tzinfo=timezone.utc)
                    self.assertEqual([r["id"] for r in events_since(ROWS, since)], ["b", "c"])

                def test_all(self):
                    since = datetime(2025, 1, 1, tzinfo=timezone.utc)
                    self.assertEqual([r["id"] for r in events_since(ROWS, since)], ["a", "b", "c"])


            unittest.main()
        '''),
        "reference": {
            "queries": ["event timestamp ts field unit"],
            "needs": ["MILLISECONDS"],
            "solution": {"events/store.py": d('''
                """Event rows come from the legacy collector as dicts: {"id": str, "ts": int, "kind": str}."""
                from datetime import datetime, timezone


                def by_kind(rows, kind):
                    return [row for row in rows if row["kind"] == kind]


                def _when(row):
                    return datetime.fromtimestamp(row["ts"] / 1000, tz=timezone.utc)


                def events_since(rows, since):
                    return sorted((row for row in rows if _when(row) >= since), key=_when)
            ''')},
            "naive": {"events/store.py": d('''
                """Event rows come from the legacy collector as dicts: {"id": str, "ts": int, "kind": str}."""
                from datetime import datetime, timezone


                def by_kind(rows, kind):
                    return [row for row in rows if row["kind"] == kind]


                def events_since(rows, since):
                    when = lambda row: datetime.fromtimestamp(row["ts"], tz=timezone.utc)
                    return sorted((row for row in rows if when(row) >= since), key=when)
            ''')},
        },
    },
    {
        "id": "c04-gateway-superseded",
        "kind": "memory",
        "knowledge": "superseded-fact",
        "project_id": "proj_gateway",
        "prompt": "Implement `build_request(path: str) -> tuple[str, dict]` in api/request.py. It must return the full URL on the partner gateway for `path` (which starts with '/') and the headers the gateway requires.",
        "files": {
            "README.md": "# Partner gateway client\n\nBuilds requests for the partner gateway.\n",
            "api/__init__.py": "",
            "api/request.py": d('''
                """Builds requests for the partner gateway."""

                TIMEOUT_SECONDS = 10
            '''),
        },
        "memory": [
            {"id": "gateway-v1", "title": "Partner gateway base URL", "text": "Partner gateway base URL is https://api-v1.partner.example.test and requests need no extra headers.", "observed_at": "2025-09-01T00:00:00Z"},
            {"id": "gateway-v2", "title": "Partner gateway base URL (current)", "text": "Since 2026-05 the partner gateway base URL is https://edge.partner.example.test/v2 and every request must send the header X-Client: kestrel-app. The old v1 host is shut down.", "supersedes": "gateway-v1", "observed_at": "2026-05-04T00:00:00Z"},
        ],
        "memory_only": ["partner.example.test", "kestrel-app", "X-Client"],
        "hidden_test": d('''
            import unittest
            from api.request import build_request


            class T(unittest.TestCase):
                def test_request(self):
                    url, headers = build_request("/orders/7")
                    self.assertEqual(url, "https://edge.partner.example.test/v2/orders/7")
                    self.assertEqual(headers.get("X-Client"), "kestrel-app")


            unittest.main()
        '''),
        "reference": {
            "queries": ["partner gateway base URL headers"],
            "needs": ["edge.partner.example.test"],
            "must_not_retrieve": ["api-v1.partner.example.test"],
            "solution": {"api/request.py": d('''
                """Builds requests for the partner gateway."""

                TIMEOUT_SECONDS = 10
                BASE_URL = "https://edge.partner.example.test/v2"


                def build_request(path):
                    return BASE_URL + path, {"X-Client": "kestrel-app"}
            ''')},
            "naive": {"api/request.py": d('''
                """Builds requests for the partner gateway."""

                TIMEOUT_SECONDS = 10
                BASE_URL = "https://api.partner.example.com"


                def build_request(path):
                    return BASE_URL + path, {"Accept": "application/json"}
            ''')},
        },
    },
    {
        "id": "c05-deprecated-save",
        "kind": "memory",
        "knowledge": "deprecated-api",
        "project_id": "proj_orders",
        "prompt": "Add `archive_order(order)` to orders.py that persists the order (a dict with an 'id' key) through the project's storage layer and returns the storage key.",
        "files": {
            "README.md": "# Orders\n\nOrder helpers on top of the in-process store.\n",
            "store/__init__.py": "",
            "store/records.py": d('''
                _DB = {}


                def save(obj):
                    """Persist a dict keyed by obj['id']."""
                    _DB[obj["id"]] = dict(obj)
                    return obj["id"]


                def put_record(namespace, key, value):
                    """Persist value under namespace/key."""
                    _DB[f"{namespace}/{key}"] = dict(value)
                    return f"{namespace}/{key}"


                def get(key):
                    return _DB.get(key)
            '''),
            "orders.py": d('''
                from store import records


                def total(order):
                    return sum(line["qty"] * line["price"] for line in order["lines"])
            '''),
        },
        "memory": [
            {"id": "deprecate-store-save", "title": "store.records.save is deprecated", "text": "store.records.save() is deprecated because it bypasses the audit trail; new code must call store.records.put_record(namespace, key, value), using the namespace 'orders' for orders."},
        ],
        "memory_only": ["deprecated", "audit trail"],
        "hidden_test": d('''
            import unittest
            from store import records
            import orders


            class T(unittest.TestCase):
                def test_archive(self):
                    key = orders.archive_order({"id": "o1", "lines": []})
                    self.assertEqual(key, "orders/o1")
                    self.assertIsNotNone(records.get("orders/o1"))
                    self.assertNotIn("o1", records._DB)


            unittest.main()
        '''),
        "reference": {
            "queries": ["persist order storage layer"],
            "needs": ["put_record"],
            "solution": {"orders.py": d('''
                from store import records


                def total(order):
                    return sum(line["qty"] * line["price"] for line in order["lines"])


                def archive_order(order):
                    return records.put_record("orders", order["id"], order)
            ''')},
            "naive": {"orders.py": d('''
                from store import records


                def total(order):
                    return sum(line["qty"] * line["price"] for line in order["lines"])


                def archive_order(order):
                    return records.save(order)
            ''')},
        },
    },
    {
        "id": "c06-billing-decimal-paths",
        "kind": "memory",
        "knowledge": "path-scoped-rule",
        "project_id": "proj_billing",
        "prompt": "Implement `apply_discount(amount, percent)` in billing/discounts.py returning the discounted amount, following this module's money rules.",
        "files": {
            "README.md": "# Billing\n\nInvoices and reporting.\n",
            "billing/__init__.py": "",
            "billing/discounts.py": '"""Discount rules for invoices."""\n',
            "reports/__init__.py": "",
            "reports/charts.py": "def scale(values, factor):\n    return [v * factor for v in values]\n",
        },
        "memory": [
            {"id": "rule-billing-decimal", "title": "Money rules in billing", "text": "In billing/, amounts are decimal.Decimal end to end and never float; results are quantized to 2 decimal places with ROUND_HALF_UP.", "paths": ["billing/**"]},
            {"id": "rule-reports-float", "title": "Number rules in reports", "text": "In reports/, plain floats are fine; values are rounded only when rendered.", "paths": ["reports/**"]},
        ],
        "memory_only": ["HALF_UP", "Decimal"],
        "hidden_test": d('''
            import unittest
            from decimal import Decimal
            from billing.discounts import apply_discount


            class T(unittest.TestCase):
                def test_discount(self):
                    result = apply_discount(Decimal("5.35"), 50)
                    self.assertIsInstance(result, Decimal)
                    self.assertEqual(result, Decimal("2.68"))
                    self.assertEqual(apply_discount(Decimal("19.99"), 15), Decimal("16.99"))
                    self.assertEqual(apply_discount(Decimal("0.05"), 50), Decimal("0.03"))


            unittest.main()
        '''),
        "reference": {
            "queries": ["discount money rules"],
            "paths": ["billing/discounts.py"],
            "needs": ["ROUND_HALF_UP"],
            "solution": {"billing/discounts.py": d('''
                """Discount rules for invoices."""
                from decimal import Decimal, ROUND_HALF_UP


                def apply_discount(amount, percent):
                    result = Decimal(amount) * (Decimal(100) - Decimal(percent)) / Decimal(100)
                    return result.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
            ''')},
            "naive": {"billing/discounts.py": d('''
                """Discount rules for invoices."""


                def apply_discount(amount, percent):
                    return round(float(amount) * (100 - percent) / 100, 2)
            ''')},
        },
    },
    {
        "id": "c07-error-code-registry",
        "kind": "memory",
        "knowledge": "convention",
        "project_id": "proj_users",
        "prompt": "create_user in users/service.py must reject an email address that has no '@'. Raise the project's standard error with the correct code for this case and do not store the user.",
        "files": {
            "README.md": "# Users\n\nUser service.\n",
            "users/__init__.py": "",
            "users/errors.py": d('''
                class AppError(Exception):
                    """Service error with a stable machine-readable code."""

                    def __init__(self, code, message):
                        super().__init__(f"{code}: {message}")
                        self.code = code
                        self.message = message
            '''),
            "users/service.py": d('''
                _USERS = {}


                def create_user(email, name):
                    user = {"email": email, "name": name}
                    _USERS[email] = user
                    return user
            '''),
        },
        "memory": [
            {"id": "registry-error-codes", "title": "Error code registry", "text": "Error code registry: validation errors raise AppError with codes of the form E-VAL-NNN. E-VAL-013 (phone format) is the last one issued; the invalid email code is reserved as E-VAL-014."},
        ],
        "memory_only": ["E-VAL"],
        "hidden_test": d('''
            import unittest
            from users.errors import AppError
            from users import service


            class T(unittest.TestCase):
                def test_reject(self):
                    with self.assertRaises(AppError) as caught:
                        service.create_user("not-an-email", "X")
                    self.assertEqual(caught.exception.code, "E-VAL-014")
                    self.assertNotIn("not-an-email", service._USERS)

                def test_accept(self):
                    self.assertEqual(service.create_user("a@b.test", "A")["email"], "a@b.test")


            unittest.main()
        '''),
        "reference": {
            "queries": ["error code invalid email validation"],
            "needs": ["E-VAL-014"],
            "solution": {"users/service.py": d('''
                from users.errors import AppError

                _USERS = {}


                def create_user(email, name):
                    if "@" not in email:
                        raise AppError("E-VAL-014", "invalid email address")
                    user = {"email": email, "name": name}
                    _USERS[email] = user
                    return user
            ''')},
            "naive": {"users/service.py": d('''
                from users.errors import AppError

                _USERS = {}


                def create_user(email, name):
                    if "@" not in email:
                        raise AppError("invalid_email", "invalid email address")
                    user = {"email": email, "name": name}
                    _USERS[email] = user
                    return user
            ''')},
        },
    },
    {
        "id": "c08-csv-export-format",
        "kind": "memory",
        "knowledge": "past-decision",
        "project_id": "proj_export",
        "prompt": "Implement `export_csv(rows, path)` in export/csvout.py: write a header row from the keys of the first dict, then one line per row, in the format our customers' spreadsheet tooling expects.",
        "files": {
            "README.md": "# Export\n\nCustomer downloads.\n",
            "export/__init__.py": "",
            "export/csvout.py": '"""CSV exports for customer downloads."""\n',
        },
        "memory": [
            {"id": "decision-csv-format", "title": "Customer CSV format decision", "text": "Decision from the 2025-11 support ticket batch: customer CSV downloads use ';' as the field delimiter and are written as UTF-8 with a BOM (encoding utf-8-sig) so Excel in European locales opens them correctly."},
        ],
        "memory_only": ["utf-8-sig", "BOM", "delimiter"],
        "hidden_test": d('''
            import os, tempfile, unittest
            from export.csvout import export_csv


            class T(unittest.TestCase):
                def test_export(self):
                    path = os.path.join(tempfile.mkdtemp(), "out.csv")
                    export_csv([{"name": "a", "amount": 1}, {"name": "b", "amount": 2}], path)
                    raw = open(path, "rb").read()
                    self.assertTrue(raw.startswith(b"\\xef\\xbb\\xbf"))
                    lines = raw[3:].decode("utf-8").splitlines()
                    self.assertEqual(lines[:3], ["name;amount", "a;1", "b;2"])


            unittest.main()
        '''),
        "reference": {
            "queries": ["customer CSV export format"],
            "needs": ["utf-8-sig"],
            "solution": {"export/csvout.py": d('''
                """CSV exports for customer downloads."""
                import csv


                def export_csv(rows, path):
                    with open(path, "w", encoding="utf-8-sig", newline="") as stream:
                        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), delimiter=";")
                        writer.writeheader()
                        writer.writerows(rows)
            ''')},
            "naive": {"export/csvout.py": d('''
                """CSV exports for customer downloads."""
                import csv


                def export_csv(rows, path):
                    with open(path, "w", encoding="utf-8", newline="") as stream:
                        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
                        writer.writeheader()
                        writer.writerows(rows)
            ''')},
        },
    },
    {
        "id": "c09-renamed-feature-flag",
        "kind": "memory",
        "knowledge": "corrected-fact",
        "project_id": "proj_checkout",
        "prompt": "Route checkout() in checkout/flow.py to new_checkout when the new checkout feature flag is enabled (use checkout.flags.is_enabled), otherwise keep the legacy flow.",
        "files": {
            "README.md": "# Checkout\n\nCheckout flows.\n",
            "checkout/__init__.py": "",
            "checkout/flags.py": d('''
                _ENABLED = set()


                def enable(name):
                    _ENABLED.add(name)


                def reset():
                    _ENABLED.clear()


                def is_enabled(name):
                    return name in _ENABLED
            '''),
            "checkout/flow.py": d('''
                from checkout import flags


                def legacy_checkout(cart):
                    return {"flow": "legacy", "items": len(cart)}


                def new_checkout(cart):
                    return {"flow": "new", "items": len(cart)}


                def checkout(cart):
                    return legacy_checkout(cart)
            '''),
        },
        "memory": [
            {"id": "flag-name-old", "title": "New checkout feature flag name", "text": "The new checkout feature flag is named new_checkout.", "observed_at": "2025-10-01T00:00:00Z"},
            {"id": "flag-name-current", "title": "New checkout feature flag name (renamed)", "text": "The new checkout flag was renamed to checkout_v3 in 2026-03. The old flag name is permanently off and must not be read.", "supersedes": "flag-name-old", "observed_at": "2026-03-10T00:00:00Z"},
        ],
        "memory_only": ["checkout_v3"],
        "hidden_test": d('''
            import unittest
            from checkout import flags
            from checkout.flow import checkout


            class T(unittest.TestCase):
                def test_flag(self):
                    flags.reset(); flags.enable("checkout_v3")
                    self.assertEqual(checkout([1])["flow"], "new")
                    flags.reset(); flags.enable("new_checkout")
                    self.assertEqual(checkout([1])["flow"], "legacy")
                    flags.reset()
                    self.assertEqual(checkout([1])["flow"], "legacy")


            unittest.main()
        '''),
        "reference": {
            "queries": ["new checkout feature flag name"],
            "needs": ["checkout_v3"],
            "solution": {"checkout/flow.py": d('''
                from checkout import flags


                def legacy_checkout(cart):
                    return {"flow": "legacy", "items": len(cart)}


                def new_checkout(cart):
                    return {"flow": "new", "items": len(cart)}


                def checkout(cart):
                    if flags.is_enabled("checkout_v3"):
                        return new_checkout(cart)
                    return legacy_checkout(cart)
            ''')},
            "naive": {"checkout/flow.py": d('''
                from checkout import flags


                def legacy_checkout(cart):
                    return {"flow": "legacy", "items": len(cart)}


                def new_checkout(cart):
                    return {"flow": "new", "items": len(cart)}


                def checkout(cart):
                    if flags.is_enabled("new_checkout"):
                        return new_checkout(cart)
                    return legacy_checkout(cart)
            ''')},
        },
    },
    {
        "id": "c10-env-override-scheme",
        "kind": "memory",
        "knowledge": "convention",
        "project_id": "proj_config",
        "prompt": "Make load() in config/settings.py apply environment-variable overrides for nested settings (for example database.pool_size), using this project's environment variable naming scheme. Convert each value to the type of its default.",
        "files": {
            "README.md": "# Config\n\nSettings loader.\n",
            "config/__init__.py": "",
            "config/settings.py": d('''
                import copy
                import os

                DEFAULTS = {"database": {"pool_size": 5, "host": "localhost"}, "cache": {"ttl": 60}}


                def load(env=None):
                    """Return the settings dict. `env` defaults to os.environ."""
                    env = os.environ if env is None else env
                    return copy.deepcopy(DEFAULTS)
            '''),
        },
        "memory": [
            {"id": "conv-env-overrides", "title": "Environment override naming scheme", "text": "Environment override scheme: prefix BBX_, nested keys joined with a double underscore, all upper case, e.g. database.pool_size -> BBX_DATABASE__POOL_SIZE. Variables without the prefix are ignored."},
        ],
        "memory_only": ["BBX_"],
        "hidden_test": d('''
            import unittest
            from config.settings import load


            class T(unittest.TestCase):
                def test_override(self):
                    self.assertEqual(load({"BBX_DATABASE__POOL_SIZE": "7"})["database"]["pool_size"], 7)
                    self.assertEqual(load({"BBX_CACHE__TTL": "30"})["cache"]["ttl"], 30)
                    self.assertEqual(load({"DATABASE_POOL_SIZE": "9", "APP_DATABASE_POOL_SIZE": "9"})["database"]["pool_size"], 5)
                    self.assertEqual(load({})["database"]["host"], "localhost")


            unittest.main()
        '''),
        "reference": {
            "queries": ["environment variable override naming"],
            "needs": ["BBX_"],
            "solution": {"config/settings.py": d('''
                import copy
                import os

                DEFAULTS = {"database": {"pool_size": 5, "host": "localhost"}, "cache": {"ttl": 60}}


                def load(env=None):
                    """Return the settings dict. `env` defaults to os.environ."""
                    env = os.environ if env is None else env
                    settings = copy.deepcopy(DEFAULTS)
                    for section, values in settings.items():
                        for key, default in values.items():
                            name = f"BBX_{section.upper()}__{key.upper()}"
                            if name in env:
                                values[key] = type(default)(env[name])
                    return settings
            ''')},
            "naive": {"config/settings.py": d('''
                import copy
                import os

                DEFAULTS = {"database": {"pool_size": 5, "host": "localhost"}, "cache": {"ttl": 60}}


                def load(env=None):
                    """Return the settings dict. `env` defaults to os.environ."""
                    env = os.environ if env is None else env
                    settings = copy.deepcopy(DEFAULTS)
                    for section, values in settings.items():
                        for key, default in values.items():
                            name = f"APP_{section.upper()}_{key.upper()}"
                            if name in env:
                                values[key] = type(default)(env[name])
                    return settings
            ''')},
        },
    },
    {
        "id": "c11-control-paginate",
        "kind": "control",
        "knowledge": "none",
        "project_id": "proj_util",
        "prompt": "paginate() in util/paging.py returns the wrong items: page numbers are 1-based, as its docstring says. Fix it.",
        "files": {
            "README.md": "# Util\n\nSmall helpers.\n",
            "util/__init__.py": "",
            "util/paging.py": d('''
                def paginate(items, page, size):
                    """Return the items for a 1-based page number."""
                    start = page * size
                    return list(items)[start:start + size]
            '''),
        },
        "memory": [
            {"id": "note-admin-rows", "title": "Admin table rows", "text": "The admin UI tables show 25 rows by default and remember the user's choice per table."},
        ],
        "memory_only": [],
        "hidden_test": d('''
            import unittest
            from util.paging import paginate


            class T(unittest.TestCase):
                def test_pages(self):
                    self.assertEqual(paginate(range(10), 1, 3), [0, 1, 2])
                    self.assertEqual(paginate(range(10), 4, 3), [9])
                    self.assertEqual(paginate(range(10), 5, 3), [])


            unittest.main()
        '''),
        "reference": {
            "queries": ["pagination"],
            "needs": [],
            "solution": {"util/paging.py": d('''
                def paginate(items, page, size):
                    """Return the items for a 1-based page number."""
                    start = (page - 1) * size
                    return list(items)[start:start + size]
            ''')},
        },
    },
    {
        "id": "c12-harm-stale-default",
        "kind": "harm-control",
        "knowledge": "stale-memory-vs-current-code",
        "project_id": "proj_catalog",
        "prompt": "Implement list_items in catalog/listing.py: return the first `size` items, using the project's default page size when size is None.",
        "files": {
            "README.md": "# Catalog\n\nCatalog listing.\n",
            "catalog/__init__.py": "",
            "catalog/settings.py": "DEFAULT_PAGE_SIZE = 50\n",
            "catalog/listing.py": d('''
                from catalog import settings


                def list_items(items, size=None):
                    """Return the first page of items."""
                    raise NotImplementedError
            '''),
        },
        "memory": [
            {"id": "stale-page-size", "title": "Catalog default page size", "text": "Catalog default page size is 20 (DEFAULT_PAGE_SIZE in catalog/settings.py).", "observed_at": "2025-03-01T00:00:00Z"},
        ],
        "memory_only": [],
        "hidden_test": d('''
            import unittest
            from catalog.listing import list_items


            class T(unittest.TestCase):
                def test_default(self):
                    self.assertEqual(len(list_items(list(range(100)))), 50)
                    self.assertEqual(list_items(list(range(5)), 2), [0, 1])


            unittest.main()
        '''),
        "reference": {
            "queries": ["catalog default page size"],
            "needs": [],
            "solution": {"catalog/listing.py": d('''
                from catalog import settings


                def list_items(items, size=None):
                    """Return the first page of items."""
                    if size is None:
                        size = settings.DEFAULT_PAGE_SIZE
                    return list(items)[:size]
            ''')},
        },
    },
]

for _task in TASKS:
    _task["family"] = "coding"
    _task["memory"] = _task["memory"] + DISTRACTORS
