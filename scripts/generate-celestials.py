#!/usr/bin/env python3
"""Generate celestial restock events with proper fingerprints"""

import json

CELESTIALS = [
    (1753543500, "Starweaver", 1),
    (1753997100, "Starweaver", 2),
    (1754348640, "Starweaver", 3),
    (1755786600, "Starweaver", 4),
    (1756397100, "Starweaver", 5),
    (1756429800, "Starweaver", 6),
    (1756866600, "Starweaver", 7),
    (1757560246, "Starweaver", 8),
    (1757690400, "Starweaver", 9),
    (1759283700, "Starweaver", 10),
    (1759644326, "Moonbinder", 1),
    (1759912853, "Dawnbinder", 1),
    (1760120141, "Starweaver", 11),
    (1760280953, "Starweaver", 12),
    (1760873737, "Dawnbinder", 2),
    (1760991934, "Moonbinder", 2),
    (1761050128, "Dawnbinder", 3),
    (1761834015, "Moonbinder", 3),
    (1761884452, "Starweaver", 13),
    (1762033802, "Moonbinder", 4),
    (1762050947, "Dawnbinder", 4),
    (1762551901, "Dawnbinder", 5),
    (1762971900, "Starweaver", 14),
    (1762982100, "Moonbinder", 5),
    (1763086500, "Dawnbinder", 6),
    (1763937000, "Moonbinder", 6),
    (1764630300, "Starweaver", 15),
    (1764661500, "Dawnbinder", 7),
    (1764936600, "Starweaver", 16),
    (1765580700, "Moonbinder", 7),
    (1766058300, "Dawnbinder", 8),
    (1766441100, "Starweaver", 17),
    (1766874600, "Moonbinder", 8),
    (1767486300, "Moonbinder", 9),
    (1767518400, "Starweaver", 18),
    (1767833700, "Starweaver", 19),
    (1767951300, "Dawnbinder", 9),
    (1768686000, "Starweaver", 20),
    (1768915200, "Moonbinder", 10),
    (1769151000, "Dawnbinder", 10),
    (1769538600, "Starweaver", 21),
]

events = []
for ts_sec, name, stock in CELESTIALS:
    ts_ms = ts_sec * 1000
    item_id = f"{name}Pod"
    fingerprint = f"seed:{ts_ms}:{item_id}:{stock}"

    event = {
        "timestamp": ts_ms,
        "shop_type": "seed",
        "items": [{"itemId": item_id, "stock": stock}],
        "fingerprint": fingerprint
    }
    events.append(event)

print(json.dumps(events, indent=2))
