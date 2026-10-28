#!/usr/bin/env python3
"""barch finance import: consolidate C6 Bank statements into Firefly III.

Reads everything in the inbox (~/.config/firefly/learning by default):
  - the checking account CSV export (EXTRATO DE CONTA CORRENTE C6 BANK)
  - closed credit card invoices (PDF, password in config.json)
  - screenshots of the open invoice (JPG/PNG, transcribed by Claude; consecutive screenshots
    may overlap, the overlap is merged and the result must add up to the subtotal on screen)

Every line is classified with the dictionary learned from Bruno's own history
(dictionary.json); what it does not know is asked in the terminal and learned. Lines already
consolidated are skipped twice over: a ledger of statement lines seen before, and a lookup of
the same amount on the same account a few days around in Firefly itself. Nothing is written
before the plan is shown and confirmed. Afterwards the inbox files move to processed/<stamp>/.

Files outside the repo (never committed): token, config.json, dictionary.json, learning/,
processed/ under ~/.config/firefly; ledger and logs under ~/.local/state/barch/finance.
"""

import argparse
import calendar
import csv
import datetime as dt
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import urllib.error
import urllib.request
from collections import Counter, defaultdict

HOME = os.path.expanduser("~")
CONF = os.path.join(HOME, ".config/firefly")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "barch/finance")
CHECKING, CARD = "C6 Bank", "Cartão de Crédito"
CREDITS, DIVIDENDS, OTHERS, TAXES = "Créditos / Estornos / Restituições", "Dividendos", "Outros", "Impostos"
MONTHS = dict(jan=1, fev=2, mar=3, abr=4, mai=5, jun=6, jul=7, ago=8, set=9, out=10, nov=11, dez=12)
# checking lines that never go to Firefly: investments move inside the C6 Bank account and show up
# in the "Rendimentos (C6 Bank)" entry Bruno writes by hand
SKIP_CHECKING = ("COMPRA DE ATIVO B3", "RESGATE DE CDB", "APLICAÇÃO DE CDB", "APLICACAO DE CDB", "EMISSAO DE CDB",
                 "CDB C6", "Tesouro Direto", "CREDITO OPERACAO B3", "ESTORNO COMPRA ATIVO")

BOLD, DIM, YEL, GRN, RED, OFF = ("\033[1m", "\033[2m", "\033[33m", "\033[32m", "\033[31m", "\033[0m") \
    if sys.stdout.isatty() else ("",) * 6


def die(msg):
    print(f"{RED}barch finance: {msg}{OFF}", file=sys.stderr)
    sys.exit(1)


def norm(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().upper()
    return re.sub(r"\s+", " ", s).strip()


def alnum(s):
    return re.sub(r"[^A-Z0-9]", "", norm(s))


def money(s):
    return float(s.replace(".", "").replace(",", "."))


def brl(v):
    return f"{v:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


# ---------------------------------------------------------------- Firefly API

class Firefly:
    def __init__(self, url, token):
        self.base = url.rstrip("/") + "/api/v1"
        self.h = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.api+json",
                  "Content-Type": "application/json"}

    def call(self, method, path, body=None):
        req = urllib.request.Request(f"{self.base}/{path}", headers=self.h, method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            die(f"{method} {path}: HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")
        except urllib.error.URLError as e:
            die(f"cannot reach Firefly ({e.reason})")

    def all(self, path):
        out, page = [], 1
        sep = "&" if "?" in path else "?"
        while True:
            d = self.call("GET", f"{path}{sep}limit=500&page={page}")
            out += d["data"]
            p = d.get("meta", {}).get("pagination") or {}
            if not p or p.get("current_page", 1) >= p.get("total_pages", 1):
                return out
            page += 1


# ---------------------------------------------------------------- parsers

def parse_csv(path):
    lines = open(path, encoding="utf-8-sig").read().splitlines()
    if not lines or "EXTRATO DE CONTA CORRENTE C6 BANK" not in lines[0]:
        return None
    start = next(i for i, l in enumerate(lines) if l.startswith("Data Lançamento"))
    items = []
    for r in csv.DictReader(lines[start:]):
        if not r.get("Data Lançamento"):
            continue
        items.append(dict(account="checking", source=os.path.basename(path), kind="checking",
                          date=dt.datetime.strptime(r["Data Lançamento"], "%d/%m/%Y").date(),
                          name=r["Título"].strip(), extra=(r["Descrição"] or "").strip(),
                          amount=round(float(r["Entrada(R$)"] or 0) - float(r["Saída(R$)"] or 0), 2)))
    return items


ITEM_RE = re.compile(r"\s+(\d\d) (jan|fev|mar|abr|mai|jun|jul|ago|set|out|nov|dez)\s+(.+?)\s{2,}(?:(.+?)\s{2,})?\s*(-?[\d.]+,\d\d)\s*$")


def parse_pdf(path, password):
    try:
        text = subprocess.run(["pdftotext", "-layout", "-upw", password, path, "-"], check=True,
                              capture_output=True, text=True).stdout
    except FileNotFoundError:
        die("pdftotext not found (package poppler)")
    except subprocess.CalledProcessError as e:
        die(f"{os.path.basename(path)}: pdftotext failed ({e.stderr.strip()[:200]}); wrong password in config.json?")
    m = re.search(r"fechamento desta fatura em (\d\d)/(\d\d)/(\d\d)", text)
    if not m:
        return None
    closing = dt.date(2000 + int(m.group(3)), int(m.group(2)), int(m.group(1)))
    card, items, subtotals = None, [], {}
    for line in text.splitlines():
        h = re.search(r"C6 Carbon (?:Virtual )?Final (\d{4}) - .*?Subtotal deste cartão R\$ ([\d.]+,\d\d)", line)
        if h:
            card = h.group(1)
            subtotals[card] = money(h.group(2))
            continue
        t = ITEM_RE.match(line)
        if not t or not card:
            continue
        day, mon, name, extra, val = t.groups()
        y = closing.year if MONTHS[mon] <= closing.month else closing.year - 1
        items.append(dict(account="card", source=os.path.basename(path), kind="card", card=card,
                          date=dt.date(y, MONTHS[mon], int(day)), name=name.strip(),
                          extra=re.sub(r"\s{2,}", " ", (extra or "").strip()), amount=money(val)))
    for it in items:
        it.update(invoice=closing, closed=True)
    return dict(items=items, subtotals=subtotals, closing=closing)


SHOT_SCHEMA = {
    "type": "object",
    "properties": {"screenshots": {"type": "array", "items": {
        "type": "object",
        "properties": {
            "file": {"type": "string"},
            "card_subtotals": {"type": "array", "items": {"type": "object", "properties": {
                "card": {"type": "string"}, "subtotal": {"type": "number"}}, "required": ["card", "subtotal"]}},
            "total": {"type": ["number", "null"]},
            "items": {"type": "array", "items": {"type": "object", "properties": {
                "date": {"type": "string", "description": "DD/MM as shown"},
                "name": {"type": "string"},
                "amount": {"type": "number", "description": "BRL, positive for a charge, negative for a credit"},
                "usd": {"type": ["number", "null"]},
                "card": {"type": "string", "description": "last 4 digits"}},
                "required": ["date", "name", "amount", "usd", "card"]}}},
        "required": ["file", "card_subtotals", "total", "items"]}}},
    "required": ["screenshots"]}


def parse_screenshots(paths):
    """Transcribe the open invoice screenshots with Claude, then merge the overlaps here."""
    if shutil.which("claude") is None:
        die("claude not found (needed to read the screenshots)")
    order = sorted(paths, key=lambda p: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", os.path.basename(p))])
    prompt = (
        "These are screenshots of the open credit card invoice in the C6 Bank app, in this order:\n"
        + "\n".join(f"- {p}" for p in order)
        + "\n\nRead every image with the Read tool. For each one, transcribe every transaction exactly as "
        "shown, top to bottom: the date (DD/MM), the merchant name with every word on the line (keep "
        "the spacing as single spaces), the BRL amount, the USD amount when a second line shows US$, "
        "and the card's last 4 digits. Lines cut at the top or bottom edge without the amount visible "
        "are left out. Also give the per-card subtotals and the invoice total ('Valor' / 'Valor a "
        "pagar') when visible on that screenshot, and the 'Outros lançamentos' subtotal as a card "
        "named 'outros'. Do not merge or deduplicate across screenshots: consecutive screenshots "
        "overlap on purpose. Be exact with digits.")
    digest = hashlib.sha1(b"".join(open(p, "rb").read() for p in order)).hexdigest()[:16]
    cache = os.path.join(STATE, f"screenshots-{digest}.json")
    if os.path.exists(cache):
        return merge_screenshots(order, json.load(open(cache)))
    print(f"{DIM}Reading {len(order)} screenshot(s) with Claude…{OFF}")
    args = ["claude", "-p", "--output-format", "json", "--permission-mode", "dontAsk", "--strict-mcp-config",
            "--json-schema", json.dumps(SHOT_SCHEMA), "--disallowedTools", "Edit", "Write", "NotebookEdit", "Bash",
            "--allowedTools", "Read"]
    for d in sorted({os.path.dirname(p) for p in order}):
        args += ["--add-dir", d]
    r = subprocess.run(args, input=prompt, capture_output=True, text=True, timeout=900)
    try:
        res = json.loads(r.stdout)
        shots = res["structured_output"]["screenshots"]
    except (ValueError, KeyError, TypeError):
        die(f"Claude could not transcribe the screenshots (exit {r.returncode}): {(r.stderr or r.stdout)[-400:]}")
    out = merge_screenshots(order, shots)
    json.dump(shots, open(cache, "w"), ensure_ascii=False)       # only once the subtotals matched
    return out


def merge_screenshots(order, shots):
    by_file = {os.path.basename(s["file"]): s for s in shots}
    merged, subtotals, total = [], {}, None
    for p in order:
        s = by_file.get(os.path.basename(p))
        if s is None:
            die(f"Claude skipped {os.path.basename(p)}")
        rows = [(x["date"], norm(x["name"]), round(x["amount"], 2), x["usd"], x["card"][-4:]) for x in s["items"]]
        k = next((k for k in range(min(len(merged), len(rows)), 0, -1) if merged[-k:] == rows[:k]), 0)
        if merged and k == 0:
            print(f"{YEL}warning: {os.path.basename(p)} does not overlap the previous screenshot; "
                  f"check nothing is missing between them{OFF}")
        merged += rows[k:]
        for c in s["card_subtotals"]:
            subtotals[c["card"][-4:] if c["card"][-4:].isdigit() else c["card"].lower()] = round(c["subtotal"], 2)
        total = s["total"] if s["total"] is not None else total
    today = dt.date.today()
    items = []
    for d, name, amt, usd, card in merged:
        day, mon = map(int, d.split("/"))
        date = dt.date(today.year, mon, day)
        if date > today:
            date = date.replace(year=today.year - 1)
        items.append(dict(account="card", source="screenshots", kind="card", card=card, date=date, name=name,
                          extra=f"USD {usd:.2f}" if usd else "", usd=usd, amount=amt, closed=False, invoice=None))
    # each card must add up to the subtotal shown
    for card, sub in subtotals.items():
        if not card.isdigit():
            continue
        got = round(sum(i["amount"] for i in items if i["card"] == card), 2)
        if abs(got - sub) > 0.005:
            die(f"screenshots: card {card} adds up to {brl(got)} but the app shows {brl(sub)}; "
                "a screenshot is missing or was misread (no overlap?)")
    return dict(items=items, subtotals=subtotals, total=total)


# ---------------------------------------------------------------- dictionary

class Dictionary:
    def __init__(self, path):
        self.path = path
        d = json.load(open(path)) if os.path.exists(path) else {}
        self.card = d.get("card", {})
        self.checking = d.get("checking", {})
        self.conventions = d.get("conventions", {})
        self.aggregate = d.get("aggregate_cards", {"2377": "Cartão - Beatriz de Renzis"})
        self._index()

    def _index(self):
        self.card_idx = sorted(((alnum(k), k) for k in self.card), key=lambda x: -len(x[0]))

    def save(self):
        tmp = self.path + ".tmp"
        json.dump(dict(card=self.card, checking=self.checking, conventions=self.conventions,
                       aggregate_cards=self.aggregate), open(tmp, "w"), ensure_ascii=False, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    def card_lookup(self, name):
        n = alnum(re.sub(r"\s+-\s+(Parcela|Estorno).*$", "", name))
        for k, raw in self.card_idx:
            if k == n or (len(k) >= 6 and n.startswith(k)) or (len(n) >= 6 and k.startswith(n)):
                return raw, self.card[raw]
        return None, None

    def card_similar(self, name):
        keys = list(self.card)
        return difflib.get_close_matches(norm(name), keys, n=3, cutoff=0.55)

    def learn_card(self, name, entry):
        key = norm(re.sub(r"\s+-\s+(Parcela|Estorno).*$", "", name))
        key = re.sub(r"^(FACEBK|PAYPAL|MP|PG|EBN|IFD)\s*\*\s*\w*$", r"\1 *", key)  # one-off ids after the star
        self.card[key] = entry
        self._index()

    def learn_checking(self, key, entry):
        self.checking[key] = entry


def checking_key(it):
    t, e = it["name"], it["extra"]
    m = re.match(r"(?i)(pix (?:enviado|recebido)(?: c6)?|devol (?:enviada|recebida) pix(?: c6)?|pix automático enviado) (?:para|de) (.+)", t)
    if m:
        kind = norm(m.group(1)).replace("PIX AUTOMATICO ENVIADO", "PIX ENVIADO")
        return f"{kind}|{norm(m.group(2))[:28]}"
    if t in ("C6TAG PEDAGIO", "C6TAG ESTACIONAMENTO", "DEBITO DE CARTAO"):
        place = norm(re.sub(r"^\w+-", "", e))
        return f"{norm(t)}|{place}"
    return norm(t)


def checking_lookup(d, key):
    if key in d.checking:
        return d.checking[key]
    # pedágio/estacionamento/débito: longest known prefix of the place ("SPVIAS SP127 1339 SUL" ~ "SPVIAS SP127")
    head, _, place = key.partition("|")
    best = None
    for k, v in d.checking.items():
        kh, _, kp = k.partition("|")
        if kh == head and kp and place.replace("CCR ", "").startswith(kp.replace("CCR ", "")) and (not best or len(kp) > len(best[0])):
            best = (kp, v)
    return best[1] if best else None


# ---------------------------------------------------------------- planning

class Entry:
    def __init__(self, items, type_, date, splits, title=None, how="auto", note=""):
        self.items, self.type, self.date, self.splits, self.title, self.how, self.note = items, type_, date, splits, title, how, note
        self.time = None
        self.existing = False

    def asset(self):
        s = self.splits[0]
        return s["source"] if s["source"] in (CHECKING, CARD) else s["destination"]

    def signed(self, s):
        """amount as seen from the asset account (checking: + in, - out; card: + charge, - credit)"""
        a = s["amount"]
        if self.asset() == CHECKING:
            return -a if s["source"] == CHECKING else a
        return a if s["source"] == CARD else -a


def split(desc, amount, src, dst, cat=None, tags=None):
    return dict(description=desc, amount=round(amount, 2), source=src, destination=dst, category=cat or None, tags=tags or [])


class Planner:
    def __init__(self, ff, dic, accounts, args):
        self.ff, self.d, self.accounts, self.args = ff, dic, accounts, args
        self.entries, self.notes = [], []
        self.expense = sorted(n for n, t in accounts.items() if t == "expense")
        self.revenue = sorted(n for n, t in accounts.items() if t == "revenue")
        self.asset = sorted(n for n, t in accounts.items() if t == "asset")
        self.categories = []

    # ---- asking
    def complete_input(self, prompt, options, default=""):
        try:
            import readline
            readline.set_completer_delims("")
            readline.set_completer(lambda text, i: ([o for o in options if norm(o).startswith(norm(text))] + [None])[i])
            readline.parse_and_bind("tab: complete")
            if default:
                readline.set_startup_hook(lambda: readline.insert_text(default))
        except ImportError:
            readline = None
        try:
            return input(prompt).strip()
        finally:
            if readline:
                readline.set_startup_hook(None)

    def ask(self, header, desc, dst, cat, outgoing=True):
        """returns (desc, dst, cat) or None to leave the line out of this import"""
        if self.args.dry_run or not sys.stdin.isatty():
            return None
        print(f"\n{BOLD}{header}{OFF}")
        accts = self.expense if outgoing else self.revenue
        kind = "despesa" if outgoing else "receita"
        d = self.complete_input("  Descrição (vazio = pular esta linha): ", [], desc)
        if not d:
            return None
        a = self.complete_input(f"  Conta de {kind} (Tab completa): ", accts + self.asset, dst or "")
        while a not in self.accounts:
            if a and self.complete_input(f"  {YEL}'{a}' não existe. Criar conta de {kind}? [s/N] {OFF}", []).lower() == "s":
                if not self.args.dry_run:
                    self.ff.call("POST", "accounts", {"name": a, "type": "expense" if outgoing else "revenue"})
                self.accounts[a] = "expense" if outgoing else "revenue"
                accts.append(a)
                break
            a = self.complete_input(f"  Conta de {kind} (Tab completa): ", accts + self.asset)
        c = self.complete_input("  Categoria (opcional, Tab completa): ", self.categories, cat or "")
        while c and c not in self.categories:
            if self.complete_input(f"  {YEL}Categoria '{c}' não existe. Criar? [s/N] {OFF}", []).lower() == "s":
                if not self.args.dry_run:
                    self.ff.call("POST", "categories", {"name": c})
                self.categories.append(c)
                break
            c = self.complete_input("  Categoria (opcional, Tab completa): ", self.categories)
        return d, a, c or None

    # ---- checking
    def plan_checking(self, items):
        last_unimed = self.last_unimed()
        for it in items:
            t = it["name"]
            if t.startswith(SKIP_CHECKING):
                continue
            key = checking_key(it)
            amt, out = abs(it["amount"]), it["amount"] < 0
            src_dst = lambda acct: (CHECKING, acct) if out else (acct, CHECKING)
            if t == "RENDIMENTOS":
                self.add([it], "deposit", it["date"], [split(f"Rendimentos - {it['extra']}", amt, DIVIDENDS, CHECKING)])
                continue
            if t.startswith("PGTO FAT CARTAO"):
                self.add([it], "transfer", it["date"], [split("Pagamento de Cartão", amt, CHECKING, CARD)])
                continue
            if t.startswith("UNIMED"):
                last_unimed = self.next_month(last_unimed)
                self.add([it], "withdrawal", it["date"], [split(f"Pagamento da Unimed - Bruno Corrêa Frutuozo ({last_unimed})", amt, CHECKING, "Seguros / Planos de Saúde")])
                continue
            hit = checking_lookup(self.d, key)
            if hit and not hit.get("ask"):
                s, dd = src_dst(hit["destination"])
                self.add([it], self.kind(s, dd), it["date"], [split(hit["description"], amt, s, dd, hit.get("category"), hit.get("tags"))])
                continue
            m = re.match(r"(?i)(?:pix enviado|pix automático enviado) para (.+)|(?:devol recebida pix(?: c6)?) de (.+)", t)
            who = (m.group(1) or m.group(2)).title() if m else None
            if hit:
                sug = (hit["description"], hit["destination"], hit.get("category"))
            elif m and m.group(2):
                sug = (f"Devolução Pix - {who}", CREDITS, None)
            elif who:
                sug = (f"Pix - {who}", OTHERS, None)
            else:
                sug = (t.title(), OTHERS if out else CREDITS, None)
            ans = self.ask(f"Conta corrente {it['date']:%d/%m/%Y}  {brl(it['amount'])}  {t}  {DIM}{it['extra']}{OFF}", *sug, outgoing=out)
            if not ans:
                self.notes.append(f"pulado: conta corrente {it['date']:%d/%m} {brl(it['amount'])} {t}")
                continue
            d_, a_, c_ = ans
            self.d.learn_checking(key, dict(description=d_, destination=a_, category=c_,
                                            **({"ask": True} if d_ != sug[0] and hit else {})))
            s, dd = src_dst(a_)
            self.add([it], self.kind(s, dd), it["date"], [split(d_, amt, s, dd, c_)], how="asked")

    def kind(self, src, dst):
        if self.accounts.get(src) == "asset" and self.accounts.get(dst) == "asset":
            return "transfer"
        return "deposit" if dst in (CHECKING, CARD) and self.accounts.get(src) != "asset" else "withdrawal"

    def last_unimed(self):
        hits = [s for g in self.ff.all("transactions?type=withdrawal&start=" + (dt.date.today() - dt.timedelta(days=120)).isoformat()
                                      + "&end=" + (dt.date.today() + dt.timedelta(days=1)).isoformat())
                for s in g["attributes"]["transactions"] if "Unimed" in s["description"]]
        m = None
        for s in sorted(hits, key=lambda s: s["date"]):
            m = re.search(r"\((\d\d/\d{4})\)", s["description"]) or m
        return m.group(1) if m else dt.date.today().strftime("%m/%Y")

    @staticmethod
    def next_month(mm_yyyy):
        m, y = map(int, mm_yyyy.split("/"))
        return f"{m % 12 + 1:02d}/{y + (m == 12)}"

    # ---- card
    def plan_card(self, items):
        groups = defaultdict(list)
        for it in items:
            groups[it["card"]].append(it)
        for card, its in groups.items():
            if card in self.d.aggregate:
                self.plan_aggregate(card, its)
                continue
            self.plan_card_items(its)

    def plan_aggregate(self, card, its):
        closed = [i for i in its if i.get("closed")]
        if not closed:
            self.notes.append(f"cartão {card} ({self.d.aggregate[card]}): {len(its)} compra(s) na fatura aberta, "
                              "lançadas como um valor só quando a fatura fechar (PDF)")
            return
        by_inv = defaultdict(list)
        for i in closed:
            by_inv[i["invoice"]].append(i)
        for inv, xs in by_inv.items():
            total = round(sum(i["amount"] for i in xs), 2)
            first = min(i["date"] for i in xs if "Parcela" not in i["name"]) if any("Parcela" not in i["name"] for i in xs) else inv
            self.add(xs, "withdrawal", first, [split(f"{self.d.aggregate[card]} ({inv.month}/{inv.year})", total, CARD, "Auxílios")])

    def plan_card_items(self, its):
        # pair foreign purchases with their IOF line
        fx, rest = defaultdict(list), []
        for it in its:
            if "IOF Transações Exterior" in it["extra"] or it.get("usd") or "USD" in it["extra"]:
                fx[(it["date"], alnum(it["name"]))].append(it)
            else:
                rest.append(it)
        tarifa_refunds = Counter(i["date"] for i in rest if i["name"].startswith("Estorno Tarifa"))
        for it in rest:
            n = it["name"]
            if n.startswith("Inclusao de Pagamento") or n.startswith("Estorno Tarifa"):
                continue
            if n.startswith("Anuidade Diferenciada"):
                if tarifa_refunds[it["date"]]:
                    tarifa_refunds[it["date"]] -= 1
                    continue
                p = re.search(r"Parcela (\d+/\d+)", n)
                self.add([it], "withdrawal", it["date"], [split(f"Tarifa - Anuidade - Carbon Black ({p.group(1) if p else ''})", it["amount"], CARD, OTHERS)])
                continue
            self.plan_card_line(it)
        for (_, _), pair in fx.items():
            self.plan_fx(pair)

    def card_header(self, it):
        return f"Cartão {it['date']:%d/%m/%Y}  {brl(it['amount'])}  {it['name']}  {DIM}{it['extra']}{OFF}"

    def resolve_card(self, it, header=None):
        raw, hit = self.d.card_lookup(it["name"])
        if hit and not hit.get("ask"):
            return (hit["description"], hit["destination"], hit.get("category")), "auto"
        if hit:
            sug = (hit["description"], hit["destination"], hit.get("category"))
        else:
            sim = self.d.card_similar(it["name"])
            sug = (self.d.card[sim[0]]["description"], self.d.card[sim[0]]["destination"], self.d.card[sim[0]].get("category")) if sim else (it["name"].title(), OTHERS, None)
            if sim:
                header = (header or self.card_header(it)) + f"\n  {DIM}parecido com: {', '.join(sim)}{OFF}"
        ans = self.ask(header or self.card_header(it), *sug, outgoing=it["amount"] >= 0)
        if not ans:
            return None, None
        entry = dict(description=ans[0], destination=ans[1], category=ans[2], seen=f"answer {dt.date.today()}")
        if hit and ans[0] != sug[0]:
            entry["ask"] = True     # the description changes per purchase (Amazon, Mercado Livre…)
        self.d.learn_card(it["name"], entry)
        return ans, "asked"

    def plan_card_line(self, it):
        n = it["name"]
        refund = n.endswith(" - Estorno") or it["amount"] < 0
        p = re.search(r" - Parcela (\d+)/(\d+)$", n)
        ans, how = self.resolve_card(it)
        if not ans:
            self.notes.append(f"pulado: cartão {it['date']:%d/%m} {brl(it['amount'])} {n}")
            return
        desc, dst, cat = ans
        date = it["date"]
        if p:
            desc = re.sub(r"\s*\(\d+/\d+\)$", "", desc) + f" ({p.group(1)}/{p.group(2)})"
            inv = it.get("invoice") or dt.date.today()
            day = min(it["date"].day, 28)
            date = dt.date(inv.year, inv.month, day)
            if date > inv:
                pm = inv.replace(day=1) - dt.timedelta(days=1)
                date = pm.replace(day=min(it["date"].day, calendar.monthrange(pm.year, pm.month)[1]))
        if refund:
            src = dst if self.accounts.get(dst) == "revenue" else CREDITS
            d2 = desc if desc.startswith("Estorno") else f"Estorno - {desc}"
            self.add([it], "deposit", date, [split(d2, abs(it["amount"]), src, CARD, cat)], how=how)
        else:
            self.add([it], "withdrawal", date, [split(desc, it["amount"], CARD, dst, cat)], how=how)

    def plan_fx(self, pair):
        pair = sorted(pair, key=lambda i: -i["amount"])
        svc = pair[0]
        iof = next((i for i in pair[1:] if "IOF" in i["extra"] or i.get("usd")), None) if len(pair) > 1 else None
        if "IOF" in svc["extra"] and len(pair) > 1:      # PDF labels the IOF line; trust the label
            iof = svc
            svc = next(i for i in pair if i is not iof)
        ans, how = self.resolve_card(svc, self.card_header(svc) + (f"  + IOF {brl(iof['amount'])}" if iof else ""))
        if not ans:
            self.notes.append(f"pulado: cartão {svc['date']:%d/%m} {brl(svc['amount'])} {svc['name']}")
            return
        desc, dst, cat = ans
        if not iof:
            self.add([svc], "withdrawal", svc["date"], [split(desc, svc["amount"], CARD, dst, cat)], how=how)
            return
        self.add([svc, iof], "withdrawal", svc["date"], [split("Serviço", svc["amount"], CARD, dst, cat),
                                                        split("IOF", iof["amount"], CARD, TAXES, cat)], title=desc, how=how)

    def add(self, items, type_, date, splits, title=None, how="auto"):
        self.entries.append(Entry(items, type_, date, splits, title, how))


# ---------------------------------------------------------------- dedup against Firefly and the ledger

def fingerprint(it, occurrence):
    return hashlib.sha1(f"{it['account']}|{it.get('card', '')}|{it['date']}|{norm(it['name'])}|{it['amount']:.2f}|{occurrence}".encode()).hexdigest()[:20]


def fingerprints(items):
    seen, out = Counter(), []
    for it in items:
        base = (it["account"], it.get("card"), it["date"], norm(it["name"]), it["amount"])
        seen[base] += 1
        out.append(fingerprint(it, seen[base]))
    return out


def load_existing(ff, accounts_ids, start):
    """Firefly splits on the two asset accounts since start: list of (asset, date, signed amount)"""
    out = []
    for name, aid in accounts_ids.items():
        end = (dt.date.today() + dt.timedelta(days=1)).isoformat()
        for g in ff.all(f"accounts/{aid}/transactions?start={start.isoformat()}&end={end}"):
            for s in g["attributes"]["transactions"]:
                a = float(s["amount"])
                if name == CHECKING:
                    v = -a if s["source_name"] == CHECKING else a
                else:
                    v = a if s["source_name"] == CARD else -a
                out.append(dict(asset=name, date=dt.date.fromisoformat(s["date"][:10]), amount=round(v, 2),
                                minute=int(s["date"][11:13]) * 60 + int(s["date"][14:16]),
                                ext=s.get("external_id"), desc=s["description"], used=False))
    return out


def find_existing(existing, asset, date, amount, window):
    best = None
    for x in existing:
        if x["used"] or x["asset"] != asset or abs(x["amount"] - amount) > 0.005:
            continue
        dd = abs((x["date"] - date).days)
        if dd <= window and (best is None or dd < best[0]):
            best = (dd, x)
    return best[1] if best else None


def drop_existing(items, existing, dic):
    """split the statement lines in (to plan, already in Firefly). Lines of aggregated cards and
    the invoice's own bookkeeping (payments, annuity refunds) go to the planner as they are."""
    todo, done = [], []
    for it in items:
        if it["account"] == "checking":
            if it["name"].startswith(SKIP_CHECKING):
                continue
            x = find_existing(existing, CHECKING, it["date"], it["amount"], 4)
        elif it["card"] in dic.aggregate or it["name"].startswith(("Inclusao de Pagamento", "Estorno Tarifa", "Anuidade")):
            x = None
        else:
            refund = it["name"].endswith(" - Estorno")
            window = 35 if " - Parcela " in it["name"] else 4
            x = find_existing(existing, CARD, it["date"], -it["amount"] if refund else it["amount"], window)
        if x:
            x["used"] = True
            done.append(it)
        else:
            todo.append(it)
    # a foreign purchase whose service line is already there keeps its IOF line out too
    keys = {(i["date"], alnum(i["name"])) for i in done if i["account"] == "card"}
    todo = [i for i in todo if not (i["account"] == "card" and "IOF" in i["extra"] and (i["date"], alnum(i["name"])) in keys)]
    return todo, done


def mark_existing(entries, existing):
    for e in entries:
        window = 35 if any(" - Parcela " in i["name"] for i in e.items) else 4
        main = e.splits[0]
        v = round(e.signed(main), 2)
        best = None
        for x in existing:
            if x["used"] or x["asset"] != e.asset() or abs(x["amount"] - v) > 0.005:
                continue
            dd = abs((x["date"] - e.date).days)
            if dd <= window and (best is None or dd < best[0]):
                best = (dd, x)
        if best:
            best[1]["used"] = True
            e.existing = True
            e.note = f"já no Firefly: {best[1]['desc']} ({best[1]['date']:%d/%m})"


# ---------------------------------------------------------------- times

def assign_times(entries):
    """Card: no time on the invoice, so a plausible one that keeps the order easy to reconcile.
    Checking: the CSV order of the day, after whatever is already in Firefly that day."""
    used = defaultdict(set)
    slot = lambda e: (e.splits[0]["category"] or "", e.splits[0]["destination"], e.splits[0]["description"])
    for e in entries:
        if e.existing:
            continue
        if e.asset() == CARD:
            cat, dst, desc = slot(e)
            if cat == "Pães" or "Padaria" in desc:
                h = 8 * 60
            elif cat == "Sorvete":
                h = 15 * 60
            elif cat in ("Pizzas", "Lanches", "Comida Japonesa", "Açaí") or desc.startswith(("iFood", "99Food", "McDonald")):
                h = 20 * 60
            elif dst == "Alimentação":
                h = 12 * 60 + 30
            elif dst.startswith("Supermercados"):
                h = 17 * 60
            elif dst.startswith("Farmácias"):
                h = 17 * 60 + 30
            else:
                h = 10 * 60
        else:
            h = 8 * 60
        while h in used[(e.asset(), e.date)]:
            h += 5
        used[(e.asset(), e.date)].add(h)
        e.time = h


def order_checking_times(entries, existing):
    """checking entries keep their CSV order inside the day, after what Firefly already has that
    day: 08:00, 08:30, … (or 15 min after the last existing entry)"""
    per_day = defaultdict(list)
    for e in entries:
        if not e.existing and e.asset() == CHECKING:
            per_day[e.date].append(e)
    for day, es in per_day.items():
        last = max((x["minute"] for x in existing if x["asset"] == CHECKING and x["date"] == day), default=None)
        t = 8 * 60 if last is None else last + 15
        step = 30 if t + 30 * len(es) < 23 * 60 + 50 else max(1, (23 * 60 + 50 - t) // max(len(es), 1))
        for e in es:
            e.time = min(t, 23 * 60 + 59)
            t += step


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(prog="barch finance import", description=__doc__.split("\n")[0])
    ap.add_argument("--dir", default=os.path.join(CONF, "learning"), help="inbox folder (default: %(default)s)")
    ap.add_argument("--dry-run", action="store_true", help="show the plan, ask nothing, write nothing")
    ap.add_argument("--yes", action="store_true", help="do not ask for the final confirmation")
    ap.add_argument("--keep", action="store_true", help="leave the files in the inbox afterwards")
    ap.add_argument("--seed", action="store_true", help="mark every line of the inbox as consolidated without importing")
    args = ap.parse_args()
    os.umask(0o077)     # ledger, logs and the screenshot cache hold financial data

    cfg_path = os.path.join(CONF, "config.json")
    cfg = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
    url = cfg.get("url") or die(f"{cfg_path}: missing \"url\"")
    token = open(os.path.join(CONF, "token")).read().strip()
    os.makedirs(STATE, exist_ok=True)
    ledger_path = os.path.join(STATE, "ledger.json")
    ledger = set(json.load(open(ledger_path))) if os.path.exists(ledger_path) else set()

    files = sorted(os.path.join(args.dir, f) for f in os.listdir(args.dir)) if os.path.isdir(args.dir) else []
    files = [f for f in files if os.path.isfile(f) and not os.path.basename(f).startswith(".")]
    if not files:
        print(f"Nada em {args.dir}.")
        return 0

    checking, card, shots, unknown, checks = [], [], [], [], []
    for f in files:
        low = f.lower()
        if low.endswith(".csv"):
            r = parse_csv(f)
            (checking.extend(r) if r is not None else unknown.append(f))
        elif low.endswith(".pdf"):
            r = parse_pdf(f, cfg.get("pdf_password", ""))
            if r is None:
                unknown.append(f)
                continue
            card.extend(r["items"])
            for c, sub in r["subtotals"].items():
                credit = lambda i: i["name"].startswith("Estorno Tarifa") or i["name"].endswith(" - Estorno")
                got = round(sum(-i["amount"] if credit(i) else i["amount"] for i in r["items"]
                                if i["card"] == c and not i["name"].startswith("Inclusao de Pagamento")), 2)
                checks.append(f"{os.path.basename(f)}: cartão {c} {brl(got)} / fatura {brl(sub)} {'ok' if abs(got - sub) < 0.01 else 'DIFERENTE'}")
        elif low.endswith((".jpg", ".jpeg", ".png", ".webp")):
            shots.append(f)
        else:
            unknown.append(f)
    if unknown:
        print(f"{YEL}Ignorados (formato desconhecido): {', '.join(map(os.path.basename, unknown))}{OFF}")
    if shots:
        r = parse_screenshots(shots)
        card.extend(r["items"])
        checks.append(f"prints: {len(r['items'])} lançamentos; subtotais conferidos: " +
                      ", ".join(f"{k} {brl(v)}" for k, v in r["subtotals"].items()))

    items = checking + card
    fps = fingerprints(items)
    if args.seed:
        ledger.update(fps)
        json.dump(sorted(ledger), open(ledger_path, "w"))
        print(f"{len(fps)} linhas marcadas como consolidadas em {ledger_path}.")
        return 0
    fresh = [(it, fp) for it, fp in zip(items, fps) if fp not in ledger]
    print(f"{len(items)} linhas lidas ({len(checking)} conta corrente, {len(card)} cartão); "
          f"{len(items) - len(fresh)} já consolidadas antes.")
    for c in checks:
        print(f"  {DIM}{c}{OFF}")
    if not fresh:
        return archive(files, args)

    ff = Firefly(url, token)
    accs = ff.all("accounts")
    accounts = {a["attributes"]["name"]: a["attributes"]["type"] for a in accs}
    ids = {a["attributes"]["name"]: a["id"] for a in accs if a["attributes"]["name"] in (CHECKING, CARD)}
    for k in [k for k, v in accounts.items() if v in ("asset", "liabilities")]:
        accounts[k] = "asset"
    dic = Dictionary(os.path.join(CONF, "dictionary.json"))
    pl = Planner(ff, dic, accounts, args)
    pl.categories = sorted(c["attributes"]["name"] for c in ff.all("categories"))

    fresh_items = [it for it, _ in fresh]
    start = min(i["date"] for i in fresh_items) - dt.timedelta(days=40)
    existing = load_existing(ff, ids, start)
    # drop the lines Firefly already has before planning, so nothing old is asked about
    todo, already = drop_existing(fresh_items, existing, dic)
    pl.plan_checking([i for i in todo if i["account"] == "checking"])
    pl.plan_card([i for i in todo if i["account"] == "card"])
    dic.save()
    mark_existing(pl.entries, existing)
    assign_times(pl.entries)
    order_checking_times(pl.entries, existing)

    new = [e for e in pl.entries if not e.existing]
    new.sort(key=lambda e: (e.date, e.time))
    print(f"\n{BOLD}Plano:{OFF} {len(new)} lançamento(s) novo(s); {len(already) + len(pl.entries) - len(new)} linha(s) já estavam no Firefly.")
    for e in new:
        s = e.splits[0]
        other = s["destination"] if s["source"] in (CHECKING, CARD) else s["source"]
        amt = sum(x["amount"] for x in e.splits)
        mark = f"{YEL}*{OFF}" if e.how == "asked" else " "
        title = e.title or s["description"]
        extra = f"  {DIM}(Serviço {brl(e.splits[0]['amount'])} + IOF {brl(e.splits[1]['amount'])}){OFF}" if len(e.splits) > 1 else ""
        print(f" {mark}{e.date:%d/%m} {e.time // 60:02d}:{e.time % 60:02d}  {'CC' if e.asset() == CHECKING else 'CT'} "
              f"{'+' if e.type == 'deposit' else ('→' if e.type == 'transfer' else '-')}{brl(amt):>10}  {title}  "
              f"{DIM}[{other}{' · ' + s['category'] if s['category'] else ''}]{OFF}{extra}")
    for n in pl.notes:
        print(f"  {YEL}{n}{OFF}")
    if args.dry_run:
        print(f"\n{DIM}--dry-run: nada foi gravado.{OFF}")
        return 0
    if new and not args.yes:
        if input(f"\nLançar {len(new)} no Firefly? [s/N] ").strip().lower() != "s":
            print("Nada foi gravado. As respostas novas ficaram no dicionário.")
            return 1

    log_path = os.path.join(STATE, f"import-{dt.datetime.now():%Y%m%d-%H%M%S}.log")
    with open(log_path, "w") as log:
        for e in new:
            date = f"{e.date.isoformat()}T{e.time // 60:02d}:{e.time % 60:02d}:00-03:00"
            tx = []
            for s in e.splits:
                ext = "barch-c6:" + hashlib.sha1(f"{date}|{s['amount']:.2f}|{s['description']}|{s['source']}|{s['destination']}".encode()).hexdigest()[:16]
                t = dict(type=e.type, date=date, amount=f"{s['amount']:.2f}", description=s["description"],
                         source_name=s["source"], destination_name=s["destination"], external_id=ext, tags=s["tags"])
                if s["category"]:
                    t["category_name"] = s["category"]
                tx.append(t)
            body = {"error_if_duplicate_hash": True, "apply_rules": True, "fire_webhooks": True, "transactions": tx}
            if e.title:
                body["group_title"] = e.title
            g = ff.call("POST", "transactions", body)
            log.write(f"transaction {g['data']['id']} {date} {e.title or e.splits[0]['description']}\n")
            log.flush()
    ledger.update(fps)
    json.dump(sorted(ledger), open(ledger_path, "w"))
    print(f"{GRN}{len(new)} lançamento(s) gravado(s).{OFF} IDs em {log_path}")
    return archive(files, args)


def archive(files, args):
    if args.keep or args.dry_run:
        return 0
    dest = os.path.join(CONF, "processed", dt.datetime.now().strftime("%Y-%m-%d-%H%M%S"))
    os.makedirs(dest, exist_ok=True)
    for f in files:
        shutil.move(f, dest)
    print(f"Arquivos movidos para {dest}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print("\nInterrompido; nada além do que já apareceu como gravado foi enviado.")
        sys.exit(130)
