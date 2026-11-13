# Finance

C6 Bank statements into Firefly III.

`barch finance import` consolidates C6 Bank statements into Firefly III
(the URL in `~/.config/firefly/config.json`). Drop the files in `~/.config/firefly/learning/` and run it:

- the checking account CSV export, the closed card invoices (PDF) and, for the invoice that is
  still open (the app does not export it), screenshots of it with the last two entries of each
  repeated at the top of the next. Claude reads the screenshots; the overlap is merged and each
  card has to add up to the subtotal on screen, or nothing goes in.
- every line is classified with `~/.config/firefly/dictionary.json`, learned from the Firefly
  history (descriptions, accounts, categories, IOF as a split, the additional card of Beatriz as one
  entry per invoice, investments left out). Unknown lines are asked in the terminal and learned;
  names whose description changes per purchase (Amazon, Mercado Livre…) are always asked, with
  the last one pre-filled.
- lines already consolidated are skipped (a ledger of lines seen, plus the same amount on the same
  account a few days around in Firefly), so repeating a file is harmless. The plan is shown before
  anything is written; afterwards the files move to `~/.config/firefly/processed/<date>/`.
- `Rendimentos (C6 Bank)` and `Rendimentos (C6 Global Invest)` stay manual (internet banking).

Token, `config.json` (URL, PDF password), dictionary and files never enter the repo; the ledger and
the import logs (IDs of everything written) are in `~/.local/state/barch/finance/`.
