# ip-catalog

Minimal vendor-IP placeholders for this tree.

| Wrapper | Use |
|---|---|
| `tx_afifo` | True CDC only (async AXIS). Same-clock paths must not instantiate it. |

Synthesis binds the wrapper to the board FIFO generator (XPM / vendor). Simulation may use a behavioral stand-in; do not treat that as CDC sign-off.
