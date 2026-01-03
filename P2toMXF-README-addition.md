## Why This Tool Exists

Panasonic P2 cameras record in **MXF OP-Atom** format, where video and each audio channel are stored as separate files:

```
CONTENTS/
├── VIDEO/
│   └── 0001AB.MXF        ← video only
└── AUDIO/
    ├── 0001AB00.MXF      ← audio channel 1
    ├── 0001AB01.MXF      ← audio channel 2
    ├── 0001AB02.MXF      ← audio channel 3
    └── 0001AB03.MXF      ← audio channel 4
```

This format works well for editing, but many MAM systems, archive solutions, and broadcast workflows expect **MXF OP1a** — a single self-contained file with video and all audio streams interleaved together.

P2toMXF converts OP-Atom to OP1a (or MOV) without re-encoding. The video and audio data remain bit-for-bit identical; only the container changes.

### OP-Atom vs OP1a

| Format | Structure | Use Case |
|--------|-----------|----------|
| **OP-Atom** | One essence per file | Camera recording, editing |
| **OP1a** | All essences in one file | Delivery, archive, MAM ingest |
